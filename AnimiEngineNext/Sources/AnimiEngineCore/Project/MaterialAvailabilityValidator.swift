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
            // CP7.5 two-clock: VIDEO availability is checked across the MEDIA span (timelineSpan +
            // transition post-roll); template ANIMATION availability only across the VISUAL span
            // (nominalDuration) because the visual clock holds at nominal when stretched.
            let mediaEnd = try CheckedInt64.add(
                scene.timelineSpan.ticks, postHalfAfter[index], "material.mediaEnd"
            )
            try checkSceneLayers(
                layers: payload.layers,
                mediaInterval: (0, mediaEnd),
                visualEnd: scene.nominalDuration.ticks,
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
            // CP7.5: media span = timelineSpan + post-roll; visual span = nominalDuration (see above).
            let mediaEnd = try CheckedInt64.add(
                scene.span.timelineSpan.ticks, post, "material.window.mediaEnd"
            )
            try checkSceneLayers(
                layers: scene.payload.layers,
                mediaInterval: (0, mediaEnd),
                visualEnd: scene.span.nominalDuration.ticks,
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

    /// Checks every scene layer (Task-002 §8.2–8.5; CP7.5 two-clock).
    ///
    /// VIDEO material is validated across the MEDIA interval `[0, mediaInterval.end)` (= timelineSpan
    /// + transition post-roll) because the media clock continues across a stretched scene. Template
    /// ANIMATION (`.becomeInactive` continuation) is validated only across the VISUAL interval
    /// `[0, visualEnd)` (= nominalDuration), because the visual clock HOLDS at the last native tick
    /// when stretched and never requests animation past nominal. For an unstretched scene
    /// `mediaInterval.end == visualEnd + postHalf`, identical to the pre-CP7.5 behavior.
    ///
    /// `bodyEnd` (== nominalDuration) only labels the cosmetic video error role ("outgoing" vs "sole").
    static func checkSceneLayers(
        layers: [SceneLayer],
        mediaInterval: (start: Int64, end: Int64),
        visualEnd: Int64,
        bodyEnd: Int64
    ) throws {
        guard mediaInterval.end > mediaInterval.start else { return }
        for layer in layers {
            // VIDEO availability over the MEDIA interval ∩ the layer's own active range.
            let lo = Swift.max(mediaInterval.start, layer.activeRange.start.ticks)
            let hi = Swift.min(mediaInterval.end, layer.activeRange.end.ticks)
            if hi > lo {
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
            }

            // §8.5 (CP7.5 VISUAL): a `.becomeInactive` animation must cover the layer's visible
            // interval up to the VISUAL end (nominal). The last VISUAL tick the layer is shown at is
            // `min(layer.activeRange.end, visualEnd) - 1` — the held tail past nominal never requests
            // animation, so the stretched span imposes no extra animation requirement.
            if let animation = layer.animation, animation.ifShorter == .becomeInactive {
                let visualHi = Swift.min(visualEnd, layer.activeRange.end.ticks)
                let visualLo = layer.activeRange.start.ticks
                if visualHi > visualLo {
                    let lastVisualTick = visualHi - 1
                    if lastVisualTick >= animation.authoredDuration.ticks {
                        throw ProjectValidationError.unavailableAnimationContinuation(layer: layer.id.raw)
                    }
                }
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
