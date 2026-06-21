/// The pure, immutable timeline evaluator (Task-002 plan, §13).
///
/// Given an ``EvaluationWindow`` and an exact project time `T`, it returns a render-complete
/// ``FramePlan``. It performs no IO, decoding, rendering, clocks, caching, or mutable lookup.
public enum TimelineEvaluator {

    /// Evaluates the frame plan at exact project time `T` (Task-002 plan, §13).
    public static func evaluate(_ window: EvaluationWindow, at time: ProjectTime) throws -> FramePlan {
        // 1. Reject T outside the project's half-open range.
        let projectEnd = try ProjectTime.zero.adding(window.projectDuration)
        guard time >= ProjectTime.zero, time < projectEnd else {
            throw ProjectValidationError.invalidRange(field: "evaluate.outsideProject")
        }
        // 2. Reject T outside window coverage.
        guard window.coverage.contains(time) else {
            throw ProjectValidationError.invalidEvaluationWindowCoverage
        }

        // 3. Locate an active animated transition whose window contains T.
        if let active = activeTransition(in: window, at: time) {
            let body = try buildTransition(active, window: window, at: time)
            let overlays = try buildOverlays(window: window, at: time)
            return FramePlan(output: window.output, projectTime: time, body: body, overlays: overlays)
        }

        // 4. Normal playback / cut: one .sole scene subplan.
        let scene = try soleScene(in: window, at: time)
        let sceneTime = try scene.span.sceneStart.distance(to: time)
        // CP7.5 two-clock: media continues to span; visual holds at nominal-1tick when stretched.
        let mediaTime = ScenePlaybackTime(uncheckedTicks: sceneTime.ticks)
        let visualTime = Self.clampVisual(mediaTime, nominalDuration: scene.span.nominalDuration, timelineSpan: scene.span.timelineSpan)
        let subplan = try buildSceneSubplan(
            scene: scene,
            role: .sole,
            visualPlaybackTime: visualTime,
            mediaPlaybackTime: mediaTime,
            transitionRelativeTime: nil
        )
        let overlays = try buildOverlays(window: window, at: time)
        return FramePlan(
            output: window.output,
            projectTime: time,
            body: .single(subplan),
            overlays: overlays
        )
    }

    /// Evaluates the frame plan at a frame index, converting to project time first
    /// (Task-002 plan, §10.3). Coverage validation is identical to ``evaluate(_:at:)``.
    public static func evaluate(_ window: EvaluationWindow, atFrame frame: FrameIndex) throws -> FramePlan {
        let time = try frame.projectTime(at: window.output.frameRate)
        return try evaluate(window, at: time)
    }

    // MARK: - Scene location

    private static func activeTransition(in window: EvaluationWindow, at time: ProjectTime) -> WindowTransition? {
        window.transitions.first { $0.boundary.window.contains(time) }
    }

    private static func soleScene(in window: EvaluationWindow, at time: ProjectTime) throws -> WindowScene {
        for scene in window.scenes {
            // CP7.5: a scene occupies [start, start + timelineSpan) on the project (span, not nominal),
            // so a frame in the stretched tail still resolves to this scene.
            let end = try scene.span.sceneStart.adding(scene.span.timelineSpan)
            if time >= scene.span.sceneStart && time < end {
                return scene
            }
        }
        throw ProjectValidationError.invalidRange(field: "evaluate.noSceneForTime")
    }

    /// CP7.5 VISUAL clamp: hold the template/animation clock at the last native tick — but ONLY for a
    /// STRETCHED scene (`timelineSpan > nominalDuration`). For an UNSTRETCHED scene the visual clock
    /// equals the media clock and is NEVER clamped, so the approved POST-ROLL behavior is preserved:
    /// an outgoing scene's local time continues past nominal at normal speed during a transition tail,
    /// yielding a `.holdLast` animation request (NOT a clamped `.sample`). The two "past nominal"
    /// cases are distinct: post-roll (continue) vs stretch (hold). `clampVisual` only realises the
    /// stretch hold; post-roll continuation flows through unclamped.
    private static func clampVisual(
        _ mediaTime: ScenePlaybackTime, nominalDuration: TickDuration, timelineSpan: TickDuration
    ) -> ScenePlaybackTime {
        guard timelineSpan.ticks > nominalDuration.ticks else { return mediaTime }  // unstretched → no clamp
        let lastNativeTick = max(0, nominalDuration.ticks - 1)
        if mediaTime.ticks <= lastNativeTick { return mediaTime }
        return ScenePlaybackTime(uncheckedTicks: lastNativeTick)
    }

    private static func windowScene(in window: EvaluationWindow, id: SceneInstanceID) throws -> WindowScene {
        guard let scene = window.scenes.first(where: { $0.span.sceneID == id }) else {
            throw ProjectValidationError.missingPayload(kind: "scene", id: id.raw)
        }
        return scene
    }

    // MARK: - Transition body

    private static func buildTransition(
        _ active: WindowTransition,
        window: EvaluationWindow,
        at time: ProjectTime
    ) throws -> FrameBody {
        let boundary = active.boundary
        guard case .animated(let effect) = boundary.transition.kind else {
            throw ProjectValidationError.invalidRange(field: "transition.notAnimated")
        }

        let outgoingScene = try windowScene(in: window, id: boundary.outgoingSceneID)
        let incomingScene = try windowScene(in: window, id: boundary.incomingSceneID)

        // Material availability is validated up front (corrective plan C-1): at the full-document site
        // in ProjectValidator and at the lazy-payload site in EvaluationWindowBuilder. The evaluator
        // performs no material validation, so playback never discovers a material error.

        // Exact rational progress (0 <= progress < 1 inside the half-open window).
        let (num, den) = try TransitionMath.progress(
            at: time, window: boundary.window, duration: boundary.transition.duration
        )

        // Outgoing MEDIA time: T - outgoingSceneStart, continuing past nominal end (unchanged
        // approved postRoll behavior). VISUAL time holds at nominal-1tick (D3).
        let outgoingMediaTime = try TransitionMath.outgoingSceneTime(
            at: time, outgoingSceneStart: outgoingScene.span.sceneStart
        )
        let outgoingVisualTime = Self.clampVisual(outgoingMediaTime, nominalDuration: outgoingScene.span.nominalDuration, timelineSpan: outgoingScene.span.timelineSpan)
        // Hold-first incoming MEDIA time; VISUAL clamps too (no-op unless incoming is itself stretched).
        let incomingMediaTime = try TransitionMath.incomingSceneTime(at: time, boundary: boundary.boundary)
        let incomingVisualTime = Self.clampVisual(incomingMediaTime, nominalDuration: incomingScene.span.nominalDuration, timelineSpan: incomingScene.span.timelineSpan)
        let relative = TransitionMath.transitionRelativeTime(at: time, boundary: boundary.boundary)

        let outgoingSubplan = try buildSceneSubplan(
            scene: outgoingScene,
            role: .outgoing,
            visualPlaybackTime: outgoingVisualTime,
            mediaPlaybackTime: outgoingMediaTime,
            transitionRelativeTime: relative
        )
        let incomingSubplan = try buildSceneSubplan(
            scene: incomingScene,
            role: .incoming,
            visualPlaybackTime: incomingVisualTime,
            mediaPlaybackTime: incomingMediaTime,
            transitionRelativeTime: relative
        )

        return .transition(TransitionPlan(
            effectID: effect.effectID,
            parameters: effect.parameters,
            easing: boundary.transition.easing,
            progressNumerator: num,
            progressDenominator: den,
            outgoing: outgoingSubplan,
            incoming: incomingSubplan
        ))
    }

    // MARK: - Scene subplan

    private static func buildSceneSubplan(
        scene: WindowScene,
        role: SceneRole,
        visualPlaybackTime: ScenePlaybackTime,
        mediaPlaybackTime: ScenePlaybackTime,
        transitionRelativeTime: TransitionRelativeTime?
    ) throws -> SceneSubplan {
        // CP7.5: layer visibility (activeRange) + ordering use the VISUAL clock (held at nominal),
        // so a layer authored to the native end stays visible across the stretched tail (its
        // activeRange contains nominal-1tick). Video content sampling uses the MEDIA clock.
        let ordered = scene.payload.layers
            .filter { $0.activeRange.contains(visualPlaybackTime) }
            .sorted { lhs, rhs in
                if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
                return lhs.stableOrdinal < rhs.stableOrdinal
            }

        var activeLayers: [ActiveLayer] = []
        for (order, layer) in ordered.enumerated() {
            // VIDEO target by MEDIA time (continues); IMAGE has no time. Animation by VISUAL time.
            let content = try activeContent(for: layer, atMediaTime: mediaPlaybackTime)
            let animationRequest = animationRequest(for: layer, atVisualTime: visualPlaybackTime)
            activeLayers.append(ActiveLayer(
                layerID: layer.id,
                zIndex: layer.zIndex,
                stableOrdinal: layer.stableOrdinal,
                localCompositionOrder: order,
                placement: layer.placement,
                mediaPlacement: layer.mediaPlacement,
                content: content,
                animationReference: layer.animation,
                animationRequest: animationRequest
            ))
        }

        return SceneSubplan(
            sceneID: scene.span.sceneID,
            role: role,
            visualPlaybackTime: visualPlaybackTime,
            mediaPlaybackTime: mediaPlaybackTime,
            transitionRelativeTime: transitionRelativeTime,
            layers: activeLayers
        )
    }

    private static func activeContent(
        for layer: SceneLayer,
        atMediaTime mediaTime: ScenePlaybackTime
    ) throws -> ActiveSceneContent {
        switch layer.content {
        case .image(let image):
            return .image(image)
        case .video(let binding):
            // CP7.5: video target uses the MEDIA clock (continues across the stretched span).
            // Material was validated up front (C-1); the target is never clamped.
            let target = try binding.sourceMapping.target(for: mediaTime)
            return .video(SourceRequest(
                media: binding.media,
                target: target,
                selection: .presentationIntervalContainsTarget
            ))
        }
    }

    private static func animationRequest(
        for layer: SceneLayer,
        atVisualTime visualTime: ScenePlaybackTime
    ) -> AnimationRequest? {
        guard let reference = layer.animation else { return nil }
        // CP7.5: template/layer animation uses the VISUAL clock (held at nominal when stretched).
        let animationTime = visualTime.asAnimationPlaybackTime()
        return AnimationRequestResolver.resolve(reference: reference, at: animationTime)
    }

    // MARK: - Overlays

    private static func buildOverlays(window: EvaluationWindow, at time: ProjectTime) throws -> [ActiveOverlay] {
        let active = window.overlays
            .filter { $0.entry.timeRange.contains(time) }
            .sorted { lhs, rhs in
                if lhs.entry.zIndex != rhs.entry.zIndex { return lhs.entry.zIndex < rhs.entry.zIndex }
                if lhs.entry.stableOrdinal != rhs.entry.stableOrdinal {
                    return lhs.entry.stableOrdinal < rhs.entry.stableOrdinal
                }
                return lhs.entry.overlayID.raw < rhs.entry.overlayID.raw
            }

        var overlays: [ActiveOverlay] = []
        for (order, windowOverlay) in active.enumerated() {
            let delta = try windowOverlay.entry.timeRange.start.distance(to: time)
            let playbackTime = OverlayPlaybackTime.from(projectLocalDelta: delta)
            let animationRequest: AnimationRequest?
            if let reference = windowOverlay.payload.animation {
                animationRequest = AnimationRequestResolver.resolve(
                    reference: reference, at: playbackTime.asAnimationPlaybackTime()
                )
            } else {
                animationRequest = nil
            }
            overlays.append(ActiveOverlay(
                overlayID: windowOverlay.entry.overlayID,
                zIndex: windowOverlay.entry.zIndex,
                stableOrdinal: windowOverlay.entry.stableOrdinal,
                compositionOrder: order,
                placement: windowOverlay.payload.placement,
                content: windowOverlay.payload.content,
                animationReference: windowOverlay.payload.animation,
                animationRequest: animationRequest,
                playbackTime: playbackTime
            ))
        }
        return overlays
    }
}

