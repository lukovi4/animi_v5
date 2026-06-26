/// Slice-004 Stage A — the injected audio-session adapter boundary (ADR-006 §3, ADR-012 §5 last ¶, §7).
///
/// **Protocol/value boundary only.** This is the seam through which the engine learns the *actual*
/// device output format/route after activation and asks the app to activate/deactivate its audio
/// session. It implements **no** realtime behavior: no `AVAudioEngine`, no master clock, no PCM
/// preparation, no output stage, no graph. Those are later Stage-B…H deliverables.
///
/// Ownership boundary (ADR-012 §5 last ¶): *"Session activation/deactivation remains an app lifecycle
/// responsibility exposed to the engine through an adapter contract."* The engine therefore **does not
/// own** `AVAudioSession`, never sets the app's category/mode, and reaches the session only through a
/// conforming adapter the app injects. Stage A defines that contract so it can be **faked in tests
/// without AVFoundation** — the conformance that actually talks to `AVAudioSession` lives behind this
/// protocol in a later slice and is the *only* place permitted to import the audio framework.
///
/// Query ordering (ADR-006 §3, ADR-012 §7 step 4): the actual output format/route is a fact **only
/// after** activation. `queryActualOutput()` therefore throws `RealtimeAudioBoundaryError`:
/// `.queryBeforeActivation` if called before the first `activate()`, and `.queryWhileInactive` after
/// `deactivate()` returns the adapter to its fail-closed inactive state.
public protocol AudioSessionAdapter: Sendable {

    /// Whether the app's audio session is currently active. After `deactivate()` this is `false`
    /// (fail-closed); querying output while inactive is a typed failure.
    var isActive: Bool { get }

    /// Ask the app to activate its audio session (the app owns category/mode — ADR-012 §5 last ¶).
    /// After this returns, `queryActualOutput()` is permitted. Idempotent activation semantics are an
    /// implementation concern; the contract only requires that a successful return means active.
    func activate() throws

    /// Ask the app to deactivate its audio session, returning the adapter to the inactive,
    /// fail-closed state. After this, `queryActualOutput()` throws `.queryWhileInactive` until the
    /// next successful `activate()`.
    func deactivate() throws

    /// Query the **actual** output format + route after activation (ADR-006 §3, ADR-012 §7 step 4).
    /// Requested hardware rate/I/O duration are preferences, not facts — only the value returned here
    /// is authoritative. Throws `.queryBeforeActivation` / `.queryWhileInactive` when not active.
    func queryActualOutput() throws -> AudioOutputQuery
}
