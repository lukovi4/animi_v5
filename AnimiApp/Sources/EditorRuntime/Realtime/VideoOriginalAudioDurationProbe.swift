import Foundation
import AVFoundation

/// Slice-005 Stage-9.2 — a NARROW app-side async probe + cache for the REAL audio-track duration of a
/// user video used by the video-original canonical audio path.
///
/// WHY: the video-original descriptor previously declared `sourceDuration = winEnd` (an exact LOWER bound),
/// which can exceed the source's actual audio track when a stretched scene maps a chunk past it → the
/// renderer's `segment.sourceEnd` clamp could not bound the decode and the decoder short-read on device
/// (S9.2). The canonical truth is the real audio-track length, which is only available via AVFoundation
/// (async). This actor probes it ONCE per URL, off the main thread, and caches the exact seconds so the
/// synchronous `currentAudioPlan()` build can read it without blocking.
///
/// SCOPE: AVFoundation stays confined here (app-side, like `AVFoundationPCMAssetDecoder`). It measures the
/// AUDIO TRACK's time range (not the whole-asset `.duration`, which can include a longer video track), so
/// the value is the real audible source length. No decoder/tolerance/guard-band involvement.
actor VideoOriginalAudioDurationProbe {

    /// Cached real audio-track durations (seconds) by file URL. A cached value of `nil` is NOT stored —
    /// only a successful positive probe is cached, so a transient failure can be retried.
    private var cache: [URL: Double] = [:]
    /// In-flight probes, coalesced by URL (a second caller for the same URL awaits the first task).
    private var inFlight: [URL: Task<Double?, Never>] = [:]

    /// Synchronous cache read — the value if already probed, else `nil`. Used by the (synchronous) plan
    /// build: a cache miss is FAIL-CLOSED upstream (the bridge throws) and the caller kicks `prewarm`.
    func cachedSeconds(for url: URL) -> Double? { cache[url] }

    /// Kick a background probe for `url` if not cached/in-flight. Never throws; never blocks the caller's
    /// thread beyond enqueuing. On success the result is cached for the NEXT synchronous build.
    func prewarm(_ url: URL) {
        guard cache[url] == nil, inFlight[url] == nil else { return }
        let task = Task<Double?, Never> { [url] in
            await Self.probeAudioTrackSeconds(url: url)
        }
        inFlight[url] = task
        Task { [weak self] in
            let result = await task.value
            await self?.store(url: url, seconds: result)
        }
    }

    /// Await the real audio-track seconds for `url`: cached, or probe now (coalesced). Returns `nil` if the
    /// asset has no audio track / fails to load — the caller decides (fail-closed for video-original).
    func seconds(for url: URL) async -> Double? {
        if let cached = cache[url] { return cached }
        if let existing = inFlight[url] { return await existing.value }
        let task = Task<Double?, Never> { [url] in
            await Self.probeAudioTrackSeconds(url: url)
        }
        inFlight[url] = task
        let result = await task.value
        store(url: url, seconds: result)
        return result
    }

    private func store(url: URL, seconds: Double?) {
        inFlight[url] = nil
        if let s = seconds, s.isFinite, s > 0 { cache[url] = s }
    }

    /// The actual AVFoundation probe (off-main). Loads the AUDIO track's time range and returns its duration
    /// in seconds, or `nil` if there is no audio track / load fails. CMTime → seconds via `CMTimeGetSeconds`
    /// (the conversion to the exact µs rational happens in the bridge with a single checked rounding).
    private static func probeAudioTrackSeconds(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { return nil }   // no audio track → caller fails closed
            let timeRange = try await track.load(.timeRange)
            let seconds = CMTimeGetSeconds(timeRange.duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }
}
