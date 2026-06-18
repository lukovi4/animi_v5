import Foundation

/// A benchmark-run identifier. This is the **only** identity type introduced in Task 001
/// (Task-001 plan, "Clocks & identity"). The richer
/// `ProjectRevision`/`PlaybackEpoch`/`FrameRequestID`/… identity model belongs to the pending
/// D-108 work and is explicitly out of scope here.
public struct BenchmarkRunID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Source of ``BenchmarkRunID`` values. Injected so tests are deterministic; production wires a
/// real generator (`UUIDRunIDGenerator`).
public protocol IDGenerator: Sendable {
    /// Produces the next benchmark-run identifier.
    func makeRunID() -> BenchmarkRunID
}

/// Production run-ID generator backed by `UUID`.
public struct UUIDRunIDGenerator: IDGenerator {
    public init() {}
    public func makeRunID() -> BenchmarkRunID {
        BenchmarkRunID(rawValue: UUID().uuidString)
    }
}
