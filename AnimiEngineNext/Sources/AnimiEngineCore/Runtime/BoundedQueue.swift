/// Slice-003 Stage F — a bounded queue with obsolete-first backpressure (ADR-006 §9).
///
/// Every scheduler queue (admitted worksets, decode requests, decoded surfaces, audio chunks, export
/// work) is bounded. When at capacity, the queue first drops obsolete speculative work to make room;
/// only if nothing is obsolete does admission fail. Capacity is injected (never a hardcoded depth) and
/// must be positive. Pure value type; deterministic FIFO order; no `Date`/`UUID`/randomness.
public struct BoundedQueue<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element]

    /// Fail-closed: a non-positive capacity is a typed error (ADR-006 §9 — queues are always bounded by
    /// a positive, injected depth).
    public init(capacity: Int) throws {
        guard capacity > 0 else { throw BoundedQueueError.invalidCapacity(capacity) }
        self.capacity = capacity
        self.storage = []
    }

    /// The current occupancy. Never exceeds `capacity`.
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var elements: [Element] { storage }

    /// Admit `element`. If the queue is full, evict the FIRST obsolete element (FIFO order) to make room,
    /// then append. If full with no obsolete element, reject — `capacity` is never exceeded.
    ///
    /// Returns `.success(.admitted)` when appended without eviction, `.success(.evictedObsolete(_))`
    /// when an obsolete element was dropped first, or `.failure(.rejectedFull)` when full and nothing was
    /// obsolete. `isObsolete` is a pure predicate evaluated in FIFO order.
    @discardableResult
    public mutating func admit(
        _ element: Element,
        isObsolete: (Element) -> Bool
    ) -> Result<AdmissionOutcome<Element>, BackpressureError> {
        if storage.count < capacity {
            storage.append(element)
            return .success(.admitted)
        }
        // Full: drop the first obsolete element (oldest-first) to make room.
        if let evictIndex = storage.firstIndex(where: isObsolete) {
            let evicted = storage.remove(at: evictIndex)
            storage.append(element)
            return .success(.evictedObsolete(evicted))
        }
        // Full and nothing obsolete: reject. Capacity is never exceeded.
        return .failure(.rejectedFull)
    }

    /// Remove and return the oldest element (FIFO), or `nil` when empty.
    public mutating func dequeue() -> Element? {
        guard !storage.isEmpty else { return nil }
        return storage.removeFirst()
    }

    /// Drop every element matching `predicate` (e.g. all old-epoch work after a discontinuity), keeping
    /// FIFO order of the survivors. Returns how many were removed.
    @discardableResult
    public mutating func removeAll(where predicate: (Element) -> Bool) -> Int {
        let before = storage.count
        storage.removeAll(where: predicate)
        return before - storage.count
    }
}

/// The outcome of a successful `admit` (ADR-006 §9).
public enum AdmissionOutcome<Element: Sendable>: Sendable {
    /// Appended without eviction.
    case admitted
    /// An obsolete element was evicted first to make room; the evicted element is returned.
    case evictedObsolete(Element)
}

extension AdmissionOutcome: Equatable where Element: Equatable {}

/// Why an `admit` failed (ADR-006 §9 backpressure).
public enum BackpressureError: Error, Equatable, Sendable {
    /// The queue is full and no obsolete element could be evicted.
    case rejectedFull
}

/// Fail-closed construction error for a bounded queue.
public enum BoundedQueueError: Error, Equatable, Sendable {
    case invalidCapacity(Int)
}
