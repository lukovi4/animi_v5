/// The canonical project-domain clock (Task-002 plan, §1.1, §4.1).
///
/// All project timeline arithmetic is expressed in signed-storage `Int64` ticks at exactly
/// 240,000 ticks per second. This value is chosen so that every supported output rate has an
/// exact integer ticks-per-frame (see ``FrameRate``). The timeline never uses `Float`, `Double`,
/// microseconds, or implicit frame rounding.
public enum TickClock {
    /// Exactly 240,000 ticks per second.
    public static let ticksPerSecond: Int64 = 240_000
}
