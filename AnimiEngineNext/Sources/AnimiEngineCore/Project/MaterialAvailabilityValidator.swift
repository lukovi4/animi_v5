/// Static, pure material-availability validation for scenes **and global overlays**
/// (Task-002 plan §8; corrective plan C-1, Revision 3).
///
/// Availability is a static property of the project — it does not depend on the requested time `T`.
/// This validator runs at the two sites that first see authoritative payload content:
///
/// - ``validateDocument(_:sceneSpanIndex:)`` — the **full-document path** (called by
///   ``ProjectValidator/validate(_:)``), checked before any `TimelineIndex` is created.
/// - ``validateWindowPayloads(requirement:scenes:transitions:overlays:)`` — the **lazy-payload path**
///   (called by ``EvaluationWindowBuilder``), checked before any `EvaluationWindow` is returned, on
///   the **loaded** payloads (defeating matching-ID/different-content payloads).
///
/// Both sites run the same two core routines so they cannot drift. `TimelineEvaluator` performs no
/// material validation; playback never discovers a material error.
public enum MaterialAvailabilityValidator {

    // MARK: - Full-document path

    public static func validateDocument(
        _ document: CanonicalProjectDocument,
        sceneSpanIndex: SceneSpanIndex
    ) throws {
        let manifest = document.manifest

        // post_i: the post-half of the outgoing animated boundary at the end of scene i (0 otherwise).
        var postHalfAfter = [Int64](repeating: 0, count: manifest.scenes.count)
        for (index, transition) in manifest.boundaryTransitions.enumerated() {
            if case .animated = transition.kind {
                postHalfAfter[index] = TransitionHalves(duration: transition.duration).postHalf
            }
        }

        // Index scene payloads by payload id for lookup.
        var sceneByPayloadID: [String: ResolvedScenePayload] = [:]
        for payload in document.scenePayloads { sceneByPayloadID[payload.payloadID.raw] = payload }

        for (index, scene) in manifest.scenes.enumerated() {
            guard let payload = sceneByPayloadID[scene.payloadID.raw] else { continue } // correspondence already checked
            let evaluatedEnd = try CheckedInt64.add(
                scene.nominalDuration.ticks, postHalfAfter[index], "material.evaluatedEnd"
            )
            try checkSceneLayers(
                layers: payload.layers,
                evaluatedInterval: (0, evaluatedEnd),
                bodyEnd: scene.nominalDuration.ticks
            )
        }

        // Global overlays: animation over the complete overlay-local interval.
        var overlayByPayloadID: [String: ResolvedOverlayPayload] = [:]
        for payload in document.overlayPayloads { overlayByPayloadID[payload.payloadID.raw] = payload }
        for entry in manifest.overlays {
            guard let payload = overlayByPayloadID[entry.payloadID.raw] else { continue }
            let overlayDuration = try entry.timeRange.start.distance(to: entry.timeRange.end).ticks
            try checkOverlayAnimation(
                overlayID: entry.id, animation: payload.animation, overlayDuration: overlayDuration
            )
        }
    }

    // MARK: - Lazy-payload path

    public static func validateWindowPayloads(
        requirement: EvaluationWindowRequirement,
        scenes: [WindowScene],
        transitions: [WindowTransition],
        overlays: [WindowOverlay]
    ) throws {
        // post_i for each required scene id from the required animated boundaries.
        var postHalfAfterSceneID: [String: Int64] = [:]
        for transition in transitions {
            if case .animated = transition.boundary.transition.kind {
                let postHalf = TransitionHalves(duration: transition.boundary.transition.duration).postHalf
                postHalfAfterSceneID[transition.boundary.outgoingSceneID.raw] = postHalf
            }
        }

        for scene in scenes {
            let post = postHalfAfterSceneID[scene.span.sceneID.raw] ?? 0
            let evaluatedEnd = try CheckedInt64.add(
                scene.span.nominalDuration.ticks, post, "material.window.evaluatedEnd"
            )
            try checkSceneLayers(
                layers: scene.payload.layers,
                evaluatedInterval: (0, evaluatedEnd),
                bodyEnd: scene.span.nominalDuration.ticks
            )
        }

        for overlay in overlays {
            let overlayDuration = try overlay.entry.timeRange.start.distance(to: overlay.entry.timeRange.end).ticks
            try checkOverlayAnimation(
                overlayID: overlay.entry.overlayID,
                animation: overlay.payload.animation,
                overlayDuration: overlayDuration
            )
        }
    }

    // MARK: - Shared core routines

    /// Checks every scene layer over the evaluated scene-time interval `[start, end)` (Task-002 §8.2–8.5).
    ///
    /// `bodyEnd` is the scene's nominal duration; a failing tick at or past it lies in the transition
    /// post-roll tail and is labeled `"outgoing"`, otherwise `"sole"` (cosmetic role only).
    static func checkSceneLayers(
        layers: [SceneLayer],
        evaluatedInterval: (start: Int64, end: Int64),
        bodyEnd: Int64
    ) throws {
        guard evaluatedInterval.end > evaluatedInterval.start else { return }
        for layer in layers {
            // Intersect the evaluated interval with this layer's own active range.
            let lo = Swift.max(evaluatedInterval.start, layer.activeRange.start.ticks)
            let hi = Swift.min(evaluatedInterval.end, layer.activeRange.end.ticks)
            guard hi > lo else { continue }                 // no non-empty intersection
            let firstTick = lo                              // §8.2: first = start
            let lastTick = hi - 1                           // §8.2: last = end - 1

            switch layer.content {
            case .image:
                break                                       // §8.4: images need no temporal material
            case .video(let binding):
                let firstTarget = try binding.sourceMapping.target(for: ScenePlaybackTime(uncheckedTicks: firstTick))
                let lastTarget = try binding.sourceMapping.target(for: ScenePlaybackTime(uncheckedTicks: lastTick))
                // Positive playback rate ⇒ first/last are min/max targets (§8.3).
                guard binding.sourceMapping.trimRange.contains(firstTarget),
                      binding.sourceMapping.trimRange.contains(lastTarget) else {
                    let role = lastTick >= bodyEnd ? "outgoing" : "sole"
                    throw ProjectValidationError.insufficientVideoMaterial(role: role, layer: layer.id.raw)
                }
            }

            // §8.5: a `.becomeInactive` animation cannot cover an interval after its authored end
            // while the layer is still required to be visible.
            if let animation = layer.animation, animation.ifShorter == .becomeInactive,
               lastTick >= animation.authoredDuration.ticks {
                throw ProjectValidationError.unavailableAnimationContinuation(layer: layer.id.raw)
            }
        }
    }

    /// Validates a global overlay's animation over its complete overlay-local interval
    /// `[0, overlayDuration)` (corrective plan C-1, Revision 3).
    ///
    /// `.holdLast` and `.loop` are valid continuations. `.becomeInactive` is rejected when the overlay
    /// remains active beyond its animation material (`overlayDuration > authoredDuration`). Overlays
    /// without an animation impose no requirement; overlays carry no temporal source material.
    static func checkOverlayAnimation(overlayID: OverlayID, animation: AnimationReference?, overlayDuration: Int64) throws {
        guard let animation, animation.ifShorter == .becomeInactive else { return }
        // last requested overlay-local tick is overlayDuration - 1.
        if overlayDuration > animation.authoredDuration.ticks {
            throw ProjectValidationError.unavailableAnimationContinuation(layer: overlayID.raw)
        }
    }
}
