import Foundation
import AnimiEngineCore

/// Stage 1 — a deterministic, bounded, decode-free cache in front of a `CanonicalPCMRenderer`.
///
/// Responsibilities (Stage 1 only — NO lifecycle/cutover wiring, NO media decode):
///   - cache rendered `CanonicalPCMChunk`s keyed by the deterministic `CanonicalPCMRenderKey`;
///   - coalesce concurrent renders of the SAME key into a single renderer call;
///   - evict deterministically when over capacity;
///   - invalidate by `ProjectRevision` / `PlaybackEpoch`, dropping both cached chunks AND in-flight work so a
///     stale render that completes after invalidation is NEVER stored.
///
/// EVICTION POLICY: **LRU** (least-recently-used). "Used" = inserted on a render store, OR returned on a
/// cache hit. When `count > capacity` after a store, the least-recently-used key is evicted. Recency is
/// tracked by a monotonic per-cache counter (NO wall clock / `Date` — fully deterministic given call order).
///
/// IN-FLIGHT COALESCING: implemented. The first `chunk(for:)`/`prewarm(...)` for a key starts a `Task` and
/// records it in `inFlight[key]` with a monotonic token; concurrent callers for the same key `await` that
/// same task. On completion the result is stored ONLY IF `inFlight[key]` still carries that token —
/// invalidation clears the entry, so a stale completion stores nothing.
///
/// Renderer errors are NEVER cached: a thrown render propagates to all awaiters and leaves no cached chunk.
///
/// CHUNK IDENTITY: a renderer's output is trusted ONLY if `chunk.key == requestedKey`. A renderer that
/// returns a chunk built for a different identity (mismatched revision/epoch/planIdentity/range) is a
/// fail-closed error — the cache throws `.pcmRenderFailed` and stores nothing, so a mixed-identity chunk can
/// never be returned for, or cached under, the wrong key. This check runs for the first render AND for every
/// coalesced caller (each verifies the shared task result against its own requested key).
actor CanonicalPCMRenderCache {

    private let capacity: Int
    private let renderer: CanonicalPCMRenderer

    /// Stored chunks by key.
    private var store: [CanonicalPCMRenderKey: CanonicalPCMChunk] = [:]
    /// LRU recency stamp per stored key (monotonic, deterministic — advances by one per use).
    private var lastUsed: [CanonicalPCMRenderKey: UInt64] = [:]
    private var useCounter: UInt64 = 0
    /// One in-flight render: the awaitable task plus a monotonic token. The token (NOT object identity —
    /// `Task` is a value type) is what rejects a stale completion: invalidation removes the entry, so the
    /// completing render finds either no entry or a newer token and stores nothing.
    private struct InFlight {
        let token: UInt64
        let task: Task<CanonicalPCMChunk, Error>
    }
    /// In-flight render tasks for coalescing, keyed by cache key.
    private var inFlight: [CanonicalPCMRenderKey: InFlight] = [:]
    /// Monotonic token source for in-flight renders (deterministic; advances by one per render start).
    private var inFlightCounter: UInt64 = 0

    /// PRIVATE: the only construction path is the fail-closed `make(capacity:renderer:)` factory. Keeping
    /// this private means no caller can ever build a cache with an unvalidated capacity — there is no silent
    /// clamp construction path. `capacity` is already validated `> 0` by `make`.
    private init(validatedCapacity: Int, renderer: CanonicalPCMRenderer) {
        self.capacity = validatedCapacity
        self.renderer = renderer
    }

    /// Fail-closed factory — the ONLY way to construct the cache. Rejects a non-positive capacity with a
    /// typed error (the cache must never run with a zero/negative bound; no silent clamp).
    static func make(capacity: Int, renderer: CanonicalPCMRenderer) throws -> CanonicalPCMRenderCache {
        guard capacity > 0 else {
            throw AppRealtimeAudioIntegrationError.invalidPCMRenderCacheCapacity(capacity)
        }
        return CanonicalPCMRenderCache(validatedCapacity: capacity, renderer: renderer)
    }

    /// Number of stored (rendered) chunks. In-flight work is not counted until it stores.
    var count: Int { store.count }

    // MARK: - Render entry points

    /// Best-effort prewarm: renders + stores on success, drops failure silently (Stage 1: no diagnostics).
    /// Never throws — a prewarm failure must not surface as an error to the caller.
    func prewarm(_ request: CanonicalAudioRenderRequest, key: CanonicalPCMRenderKey) async {
        _ = try? await chunk(for: request, key: key)
    }

    /// Return the cached chunk for `key`, or render (coalesced), store, and return it.
    func chunk(for request: CanonicalAudioRenderRequest, key: CanonicalPCMRenderKey) async throws -> CanonicalPCMChunk {
        // Hit: return and bump recency.
        if let cached = store[key] {
            touch(key)
            #if DEBUG
            Self.s8CacheEvent("hit", key)
            #endif
            return cached
        }
        // Coalesce: join an in-flight render for the same key. Each coalesced caller independently verifies the
        // shared render output against ITS OWN requested key (fail-closed on a mismatched-identity chunk).
        if let existing = inFlight[key] {
            #if DEBUG
            Self.s8CacheEvent("coalesced", key)
            #endif
            let chunk = try await existing.task.value
            return try Self.verifiedChunk(chunk, requestedKey: key)
        }
        #if DEBUG
        Self.s8CacheEvent("miss", key)
        #endif
        // Miss: start a render task, record it (with a fresh token) for coalescing.
        inFlightCounter &+= 1
        let token = inFlightCounter
        let task = Task { try await renderer.render(request) }
        inFlight[key] = InFlight(token: token, task: task)

        let chunk: CanonicalPCMChunk
        do {
            chunk = try await task.value
        } catch {
            // Renderer failed: never cache as success. Clear only our own in-flight entry (same token).
            if inFlight[key]?.token == token {
                inFlight[key] = nil
            }
            throw error
        }

        // Identity gate: a renderer that returns a chunk for a DIFFERENT key is fail-closed. Clear our own
        // in-flight entry and throw — do NOT store, do NOT return the mismatched chunk.
        let verified: CanonicalPCMChunk
        do {
            verified = try Self.verifiedChunk(chunk, requestedKey: key)
        } catch {
            if inFlight[key]?.token == token {
                inFlight[key] = nil
            }
            throw error
        }

        // Store ONLY if the in-flight entry for this key is still OURS (same token). Invalidation removed
        // the entry; a superseding render replaced the token. Either way → stale completion → store nothing.
        if inFlight[key]?.token == token {
            inFlight[key] = nil
            store[key] = verified
            touch(key)
            evictIfNeeded()
            #if DEBUG
            Self.s8CacheEvent("store", key)
            #endif
        }
        return verified
    }

    #if DEBUG
    /// Stage-8 cache diagnostics (DEBUG-only, behind DebugMemoryDiagnostics). Reports hit/miss/coalesced/store
    /// with the key's range + revision/epoch + a SHORT planIdentity hash (length only, not the full string) so
    /// repeated-Play cache behavior is provable from the log. NO behavior change. Marker:
    /// `preview.audio.stage8.cache.<kind>`.
    private static func s8CacheEvent(_ kind: String, _ key: CanonicalPCMRenderKey) {
        guard MemoryDiagnostics.isEnabled else { return }
        MemoryDiagnostics.event("preview.audio.stage8.cache.\(kind)",
            "range=\(key.range.start)..<\(key.range.end) "
            + "revision=\(String(describing: key.revision)) epoch=\(String(describing: key.epoch)) "
            + "planIdLen=\(key.planIdentity.utf8.count)")
    }
    #endif

    /// Fail-closed identity check: the rendered chunk MUST carry exactly the requested key. Returns the chunk
    /// on match; throws `.pcmRenderFailed` on any identity mismatch (revision/epoch/planIdentity/range).
    private static func verifiedChunk(
        _ chunk: CanonicalPCMChunk, requestedKey: CanonicalPCMRenderKey
    ) throws -> CanonicalPCMChunk {
        guard chunk.key == requestedKey else {
            throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                reason: "renderer returned chunk for key \(chunk.key) but \(requestedKey) was requested")
        }
        return chunk
    }

    // MARK: - Invalidation

    /// Remove all cached chunks AND in-flight work for `revision`. A stale in-flight completion for a removed
    /// key will find no matching `inFlight` entry and store nothing.
    func invalidate(revision: ProjectRevision) {
        removeMatching { $0.revision == revision }
    }

    /// Remove all cached chunks AND in-flight work for `epoch`.
    func invalidate(epoch: PlaybackEpoch) {
        removeMatching { $0.epoch == epoch }
    }

    /// Remove everything (stored + in-flight).
    func removeAll() {
        store.removeAll()
        lastUsed.removeAll()
        inFlight.removeAll()
    }

    // MARK: - Internals

    private func removeMatching(_ predicate: (CanonicalPCMRenderKey) -> Bool) {
        for key in store.keys where predicate(key) {
            store[key] = nil
            lastUsed[key] = nil
        }
        // Dropping the in-flight ENTRY (not cancelling) is what makes a stale completion store nothing: the
        // token check `inFlight[key]?.token == token` in `chunk(for:)` fails once the entry is gone.
        for key in inFlight.keys where predicate(key) {
            inFlight[key] = nil
        }
    }

    /// Bump a key's recency stamp.
    private func touch(_ key: CanonicalPCMRenderKey) {
        useCounter &+= 1
        lastUsed[key] = useCounter
    }

    /// Evict least-recently-used stored chunks until within capacity. Deterministic: lowest `lastUsed` first.
    private func evictIfNeeded() {
        while store.count > capacity {
            guard let victim = lastUsed.min(by: { $0.value < $1.value })?.key else { break }
            store[victim] = nil
            lastUsed[victim] = nil
        }
    }
}
