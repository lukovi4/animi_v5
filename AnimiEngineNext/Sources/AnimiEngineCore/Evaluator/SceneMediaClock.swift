/// The single shared definition of the canonical per-scene media clock (ADR-012 §1.0a item 4, §1.0b).
///
/// Both `TimelineEvaluator` (per-instant, window-level) and `ProjectValidator` (manifest-level
/// media-active domain) route through this enum so the math is defined **once** and cannot drift
/// (ADR-012 §1.0b: "`TimelineEvaluator` and `AudioEvaluator` MUST use one shared helper to derive the
/// per-scene media-active domain and `sceneMediaTime`; the math is defined once and not duplicated").
///
/// Slice-002 Stage A is a **behavior-preserving** extraction: the `sceneMediaTime` cases are lifted
/// verbatim from the lines previously inlined in `TimelineEvaluator`/`TransitionMath`, and
/// `mediaActiveDomain` from `ProjectValidator`. No audio types and no new semantics are introduced.
public enum SceneMediaClock {

    /// The role a scene plays at an evaluated instant (ADR-012 §1.0a item 4).
    public enum SceneRole: Equatable, Sendable {
        /// Normal playback / cut: the scene is the sole active body.
        case sole
        /// The outgoing scene of an active transition window (post-roll continues past nominal).
        case outgoing
        /// The incoming scene of an active transition window (held silent before the boundary).
        case incoming
    }

    /// The per-scene MEDIA-clock instant `sceneMediaTime(sceneID, T)` (ADR-012 §1.0a item 4).
    ///
    /// Lifted verbatim from `TimelineEvaluator`/`TransitionMath`:
    /// - `.sole` / `.outgoing`: `T − sceneStart`, continuing past nominal at normal speed
    ///   (post-roll; never frozen/clamped — the VISUAL clock clamp lives in the evaluator, not here);
    /// - `.incoming`: `0` while `T < boundary`; `T − boundary` while `T >= boundary` (hold-first).
    ///
    /// `boundary` is required for `.incoming` and ignored for `.sole`/`.outgoing`.
    public static func sceneMediaTime(
        role: SceneRole,
        at time: ProjectTime,
        sceneStart: ProjectTime,
        boundary: ProjectTime?
    ) throws -> ScenePlaybackTime {
        switch role {
        case .sole, .outgoing:
            // T − sceneStart, continuing past nominal end at normal speed (post-roll).
            let delta = try sceneStart.distance(to: time)
            return ScenePlaybackTime(uncheckedTicks: delta.ticks)
        case .incoming:
            guard let boundary else {
                throw ProjectValidationError.invalidRange(field: "sceneMediaTime.incomingMissingBoundary")
            }
            if time < boundary { return ScenePlaybackTime.zero }
            let delta = try boundary.distance(to: time)
            return ScenePlaybackTime(uncheckedTicks: delta.ticks)
        }
    }

    /// The half-open media-active domain `[start, end)` of a scene on the project timeline
    /// (ADR-012 §1.0b). A pure manifest-level derivation (no payloads), lifted verbatim from
    /// `ProjectValidator.mediaActiveDomain`:
    /// - `start` = sum of preceding scenes' `timelineSpan` (the same basis as `projectDuration`);
    /// - `end`   = `start + scene.timelineSpan + outgoing post-half of the boundary after this scene`
    ///   (a `cut` post-half is 0; an animated boundary extends the domain into the outgoing post-roll).
    /// The final scene has no following boundary, so its domain ends at `start + timelineSpan`.
    public static func mediaActiveDomain(
        sceneIndex index: Int,
        scenes: [SceneManifestEntry],
        boundaryTransitions: [SceneTransition]
    ) throws -> (start: ProjectTime, end: ProjectTime) {
        // Fail closed: an out-of-range scene index must throw, never runtime-trap on `0..<index` /
        // `scenes[index]` (Slice-002 Stage A cleanup).
        guard scenes.indices.contains(index) else {
            throw ProjectValidationError.invalidRange(field: "mediaDomain.sceneIndex")
        }
        var startTicks: Int64 = 0
        for i in 0..<index {
            startTicks = try CheckedInt64.add(startTicks, scenes[i].timelineSpan.ticks, "mediaDomain.start")
        }
        var endTicks = try CheckedInt64.add(startTicks, scenes[index].timelineSpan.ticks, "mediaDomain.end")
        // Outgoing post-half of the boundary that FOLLOWS this scene (boundary index == scene index).
        if index < boundaryTransitions.count {
            let transition = boundaryTransitions[index]
            let postHalf: Int64
            switch transition.kind {
            case .cut:
                postHalf = 0
            case .animated:
                postHalf = TransitionHalves(duration: transition.duration).postHalf
            }
            endTicks = try CheckedInt64.add(endTicks, postHalf, "mediaDomain.postRoll")
        }
        return (try ProjectTime(ticks: startTicks), try ProjectTime(ticks: endTicks))
    }
}
