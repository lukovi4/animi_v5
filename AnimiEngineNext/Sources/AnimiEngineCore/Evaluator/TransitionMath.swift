/// Pure transition geometry: the centered half-open window, exact rational progress, and the
/// hold-first scene-time mapping (Task-002 plan, §7.2, §7.3).
public enum TransitionMath {
    /// The centered transition window `[B - preHalf, B + postHalf)` for animated duration `D`
    /// around boundary `B` (Task-002 plan, §7.2).
    ///
    /// `preHalf = floor(D/2)`, `postHalf = D - preHalf` — the extra odd tick belongs after `B`.
    public static func window(boundary: ProjectTime, duration: TickDuration) throws -> ProjectTimeRange {
        let halves = TransitionHalves(duration: duration)
        let start = try boundary.subtracting(TickDuration(uncheckedTicks: halves.preHalf))
        let end = try boundary.adding(TickDuration(uncheckedTicks: halves.postHalf))
        return try ProjectTimeRange(start: start, end: end)
    }

    /// Exact rational progress `(T - window.start) / D`, with `0 <= progress < 1` inside the
    /// half-open window (Task-002 plan, §7.2).
    ///
    /// Returns `(numerator, denominator)`; `progress == 1` is never produced because the caller only
    /// invokes this for `T` strictly inside the window.
    public static func progress(
        at time: ProjectTime,
        window: ProjectTimeRange,
        duration: TickDuration
    ) throws -> (numerator: Int64, denominator: Int64) {
        let numerator = try window.start.distance(to: time).ticks      // >= 0, < duration inside window
        return (numerator, duration.ticks)
    }

    /// The outgoing scene's local time: `T - outgoingSceneStart`, continuing past nominal end at
    /// normal speed (Task-002 plan, §7.3). Never frozen or clamped.
    public static func outgoingSceneTime(
        at time: ProjectTime,
        outgoingSceneStart: ProjectTime
    ) throws -> ScenePlaybackTime {
        let delta = try outgoingSceneStart.distance(to: time)
        return ScenePlaybackTime(uncheckedTicks: delta.ticks)
    }

    /// The hold-first incoming scene's local time (Task-002 plan, §7.3):
    ///
    ///     if T <  B:  sceneTime = 0
    ///     if T >= B:  sceneTime = T - B
    public static func incomingSceneTime(
        at time: ProjectTime,
        boundary: ProjectTime
    ) throws -> ScenePlaybackTime {
        if time < boundary {
            return ScenePlaybackTime.zero
        }
        let delta = try boundary.distance(to: time)
        return ScenePlaybackTime(uncheckedTicks: delta.ticks)
    }

    /// The signed transition-relative time `T - B` (Task-002 plan, §4.1, §12).
    public static func transitionRelativeTime(
        at time: ProjectTime,
        boundary: ProjectTime
    ) -> TransitionRelativeTime {
        // Both are non-negative ticks; the difference is exact and may be negative before B.
        TransitionRelativeTime(ticks: time.ticks - boundary.ticks)
    }
}
