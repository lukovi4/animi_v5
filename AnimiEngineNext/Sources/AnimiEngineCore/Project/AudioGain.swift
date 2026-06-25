/// An integer linear audio gain (Slice 001, plan §3.3; ADR-012 §1).
///
/// **No `Float`/`Double`.** The canonical gain is an integer on a fixed linear scale where
/// `1_000_000` is unity and `0` is silence. DSP conversion to `Float32` is explicitly a later-slice
/// processing-boundary concern — never stored here. Out-of-range is a typed failure; the value is
/// **never clamped**. The `private` unchecked init is used only for the statically-valid `.unity`/
/// `.silent` constants (mirrors `ProjectTime.zero` / `TickDuration.zero`).
public struct AudioGain: Hashable, Comparable, Sendable {
    /// The unity (0 dB) raw value on the integer linear scale.
    public static let unityRaw: Int64 = 1_000_000

    /// The raw integer gain, in `0 ... 1_000_000`. `1_000_000` == unity, `0` == silence.
    public let raw: Int64

    public init(raw: Int64) throws {
        guard raw >= 0, raw <= AudioGain.unityRaw else {
            throw ProjectValidationError.invalidAudioGain(value: raw)   // typed; NEVER clamped
        }
        self.raw = raw
    }

    private init(uncheckedRaw raw: Int64) { self.raw = raw }

    /// Unity gain (`1_000_000`).
    public static let unity = AudioGain(uncheckedRaw: unityRaw)
    /// Silence (`0`).
    public static let silent = AudioGain(uncheckedRaw: 0)

    public static func < (lhs: AudioGain, rhs: AudioGain) -> Bool { lhs.raw < rhs.raw }
}
