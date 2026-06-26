/// Slice-004 Stage E — the realtime preview audio graph adapter (ADR-012 §2/§4/§5, ADR-006 §3/§8/§9).
///
/// This is the **first allowed AVFoundation/AVFAudio boundary** in the engine. `PreviewAudioGraph` owns
/// a **bounded software mix**: for one bounded output range it sums the active, unmuted, gain-applied
/// source chunks, runs the **summed** sample through the accepted D-213 `OutputOverloadStage`
/// (Candidate A) — i.e. the output stage runs **after** mixing, as a true output stage must — and emits
/// **one** final mixed mono buffer to the sink at an explicit anchor-derived output sample time. It
/// publishes an immutable `RealtimeSafeState` snapshot outside the realtime callback.
///
/// It deliberately does NOT: render the whole project, write a temp CAF/WAV, use `AVMutableComposition`
/// as a source of truth, loop, add transition ramps, auto-resume, mutate scheduler state directly (only
/// the existing injected `AudioRangeAdmission` contract rejects stale chunks), or mutate graph/state
/// from inside the realtime callback.
///
/// ## Canonical PCM order (the fix)
///
/// ```
/// per-source mono frames (pre-gain, pre-mix, pre-output-stage)
///   → apply mute/gain per PreparedAudioBuffer            (PreviewAudioGraph.mix)
///   → sum overlapping active sources into the bounded mix range
///   → apply OutputOverloadStage to each SUMMED sample    (D-213, post-mix)
///   → one final mixed mono buffer scheduled at the anchor-derived AVAudioTime  (sink)
/// ```
///
/// **Names are explicit.** *Source samples* = per-source mono frames, pre-gain/pre-mix/pre-output-stage.
/// *Mixed samples* = the single bounded mono frames the sink receives, post-gain/post-sum/post-output-
/// stage. Because mixing + the output stage are canonical **before** the sink, the real AV sink uses
/// **one** output player node (no per-source nodes, no per-source pre-mix saturation).
///
/// **Anchor (ADR-006 §3/§5).** The mix range's start is placed at
/// `anchor.outputSampleTime + (mixRange.start − anchor.projectSample)`; no `nil` time is ever used.
///
/// **Mixing (ADR-012 §2 "audio always mixes").** All active, unmuted sources for the bounded range are
/// summed at their authored gains; no implicit crossfade/duck/ramp.
///
/// To stay unit-testable with **no device audio**, the AV-touching operations sit behind the injected
/// `PreviewAudioOutputSink` protocol. The real `AVAudioEngine`-backed sink lives in this same file (the
/// only AV-importing type); contract tests use a deterministic fake sink. `Float32` is the DSP sample
/// type here (allowed by the narrowed sweep); `Double` appears ONLY as a local AVAudioFormat sample-rate
/// bridge inside the real sink, never as a stored or public canonical value.

#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Typed errors

public enum PreviewAudioGraphError: Error, Equatable, Sendable {
    /// Output configuration was requested before the session adapter was activated/queryable.
    case outputConfiguredBeforeActivation
    /// A mix was offered before `configureOutput()` established the actual output format/route.
    case scheduledBeforeOutputConfigured
    /// A mix was offered before a `PreviewAudioScheduleAnchor` was configured.
    case scheduledBeforeAnchorConfigured
    /// The anchor's revision/epoch does not match the mix/sources being scheduled.
    case anchorIdentityMismatch
    /// The mix range starts before the anchor's project sample (would schedule into the past).
    case mixBeforeAnchor(projectSample: Int64, anchorProjectSample: Int64)
    /// The computed output sample time is negative.
    case negativeOutputSampleTime(Int64)
    /// Int64 overflow while computing the scheduled output sample time.
    case scheduleTimeOverflow
    /// The mix range exceeds the injected bounded maximum (no whole-project mix window).
    case mixExceedsBoundedMax(requested: Int64, max: Int64)
    /// The mix range was empty.
    case emptyMixRange
    /// A source chunk's range does not exactly cover the requested mix range (no partial/implicit pad).
    case sourceRangeMismatch
    /// A source's supplied sample count does not match the mix frame count (mono-frame contract).
    case sampleCountMismatch(expected: Int64, got: Int)
    /// A non-positive injected bounded-max-chunk size.
    case invalidBoundedMax(Int64)
}

// MARK: - Schedule anchor (pure value, ADR-006 §3/§5)

/// One scheduler-controlled anchor binding a canonical 48 kHz project-sample coordinate to an AV output
/// sample time, for a specific revision+epoch. Pure value; frozen for the epoch by the caller.
public struct PreviewAudioScheduleAnchor: Equatable, Sendable {
    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    /// The canonical 48 kHz project-sample coordinate of the anchor.
    public let projectSample: Int64
    /// The AV/output sample time at which `projectSample` is audible.
    public let outputSampleTime: Int64

    public init(
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        projectSample: Int64,
        outputSampleTime: Int64
    ) {
        self.revision = revision
        self.epoch = epoch
        self.projectSample = projectSample
        self.outputSampleTime = outputSampleTime
    }

    /// `scheduledOutputSampleTime = outputSampleTime + (mixStartProjectSample − projectSample)`.
    /// Fail-closed: mix must not start before the anchor; subtraction/addition are overflow-checked;
    /// result must be non-negative.
    public func scheduledOutputSampleTime(forMixStart mixStartProjectSample: Int64) throws -> Int64 {
        guard mixStartProjectSample >= projectSample else {
            throw PreviewAudioGraphError.mixBeforeAnchor(
                projectSample: mixStartProjectSample, anchorProjectSample: projectSample)
        }
        let delta: Int64
        do {
            delta = try CheckedInt64.subtract(
                mixStartProjectSample, projectSample, "PreviewAudioScheduleAnchor.delta")
        } catch { throw PreviewAudioGraphError.scheduleTimeOverflow }
        let scheduled: Int64
        do {
            scheduled = try CheckedInt64.add(
                outputSampleTime, delta, "PreviewAudioScheduleAnchor.scheduled")
        } catch { throw PreviewAudioGraphError.scheduleTimeOverflow }
        guard scheduled >= 0 else { throw PreviewAudioGraphError.negativeOutputSampleTime(scheduled) }
        return scheduled
    }
}

// MARK: - One source's contribution to a bounded mix

/// One admitted source's mono contribution to a bounded mix range. `samples` are the **pre-gain,
/// pre-mix, pre-output-stage** mono frames for that source over exactly the mix range.
public struct PreviewMixSource: Sendable {
    public let buffer: PreparedAudioBuffer
    public let samples: [Float32]
    public init(buffer: PreparedAudioBuffer, samples: [Float32]) {
        self.buffer = buffer
        self.samples = samples
    }
}

// MARK: - Injected output sink (the AV seam)

/// The injected boundary the graph schedules the **single final mixed** PCM through. The real
/// implementation drives ONE output `AVAudioPlayerNode`; the test fake records calls deterministically.
/// `scheduleMixed` receives samples that have ALREADY been gain/mute-applied, summed, and passed through
/// `OutputOverloadStage` (never un-clamped, never non-finite), **and** an explicit output sample time.
public protocol PreviewAudioOutputSink: Sendable {
    /// Configure the sink for the actual queried output format (called once, after activation).
    func configure(outputFormat: AudioOutputFormat, route: AudioOutputRoute) throws
    /// Schedule one bounded final **mixed mono** buffer at an explicit output sample time. No I/O beyond
    /// the device hand-off; no temp file; no whole-project buffering.
    func scheduleMixed(
        range: AudioSampleRange,
        samples: [Float32],
        at outputSampleTime: Int64
    ) throws
}

// MARK: - The preview graph (owns the bounded software mix; AV behind the sink)

/// Orchestrates anchor-relative scheduling + bounded admission + per-source gain/mute + summation +
/// post-mix output stage. A `final class` because it owns mutable published state (`RealtimeSafeState`)
/// updated only OUTSIDE the realtime callback; the callback (in the real sink) reads the snapshot.
public final class PreviewAudioGraph: @unchecked Sendable {

    private let session: AudioSessionAdapter
    private let sink: PreviewAudioOutputSink
    /// Injected bounded maximum mix size in samples (ADR-006 §9 — runtime config, not hardcoded).
    private let maxChunkSamples: Int64

    private var outputConfigured = false
    private var configuredFormat: AudioOutputFormat?
    private var configuredRoute: AudioOutputRoute?
    private var anchor: PreviewAudioScheduleAnchor?

    /// The latest published, callback-visible snapshot (read off the callback only).
    public private(set) var publishedState: RealtimeSafeState

    public init(
        session: AudioSessionAdapter,
        sink: PreviewAudioOutputSink,
        epoch: PlaybackEpoch,
        revision: ProjectRevision,
        maxChunkSamples: Int64
    ) throws {
        guard maxChunkSamples > 0 else {
            throw PreviewAudioGraphError.invalidBoundedMax(maxChunkSamples)
        }
        self.session = session
        self.sink = sink
        self.maxChunkSamples = maxChunkSamples
        self.publishedState = .initial(epoch: epoch, revision: revision)
    }

    /// Configure output from the **actual** session route/format (ADR-006 §3). Requires the adapter to
    /// be active — querying before activation is a typed failure (fail-closed).
    public func configureOutput() throws {
        let query: AudioOutputQuery
        do {
            query = try session.queryActualOutput()
        } catch {
            throw PreviewAudioGraphError.outputConfiguredBeforeActivation
        }
        try sink.configure(outputFormat: query.format, route: query.route)
        configuredFormat = query.format
        configuredRoute = query.route
        outputConfigured = true
    }

    /// Install the scheduler-controlled anchor for this epoch (ADR-006 §3/§5). Frozen per epoch.
    public func configureAnchor(_ anchor: PreviewAudioScheduleAnchor) {
        self.anchor = anchor
    }

    public var actualOutputFormat: AudioOutputFormat? { configuredFormat }
    public var actualOutputRoute: AudioOutputRoute? { configuredRoute }
    public var scheduleAnchor: PreviewAudioScheduleAnchor? { anchor }

    /// The unity gain raw value reused for the gain multiplier (avoids a magic constant).
    private static let gainUnityRaw = AudioGain.unityRaw

    /// Mix and schedule one bounded output range from its admitted source contributions.
    ///
    /// Pipeline (all outside any realtime callback):
    /// 1. require output configured AND an anchor;
    /// 2. boundedness — mix range non-empty and `<= maxChunkSamples` (no whole-project mix);
    /// 3. for EACH source: admit via the existing `AudioRangeAdmission` contract (a stale revision/epoch
    ///    source is **rejected** — the whole mix is rejected, nothing scheduled), check anchor identity,
    ///    require the source range to exactly cover the mix range, and the sample count to match;
    /// 4. apply per-source mute/gain, then SUM into the bounded mix accumulator;
    /// 5. apply `OutputOverloadStage` (D-213 Candidate A) to each SUMMED sample — non-finite fails
    ///    closed (no sink scheduling);
    /// 6. compute the explicit anchor-relative output sample time and emit ONE final mixed mono buffer;
    ///    publish a new `RealtimeSafeState`.
    @discardableResult
    public func scheduleMix(
        range mixRange: AudioSampleRange,
        sources: [PreviewMixSource],
        against snapshot: SchedulerSnapshot
    ) throws -> ChunkScheduleOutcome {
        guard outputConfigured else { throw PreviewAudioGraphError.scheduledBeforeOutputConfigured }
        guard let anchor = anchor else { throw PreviewAudioGraphError.scheduledBeforeAnchorConfigured }

        // 2. Boundedness of the mix window (ADR-006 §9 / ADR-005 §8).
        guard !mixRange.isEmpty else { throw PreviewAudioGraphError.emptyMixRange }
        let frameCount = mixRange.sampleCount
        guard frameCount <= maxChunkSamples else {
            throw PreviewAudioGraphError.mixExceedsBoundedMax(
                requested: frameCount, max: maxChunkSamples)
        }

        // 4. Per-source admission + gain/mute, summed into the accumulator.
        var accumulator = [Float32](repeating: 0, count: Int(frameCount))
        for source in sources {
            // 3. Stale-source rejection through the EXISTING injected admission contract.
            switch AudioRangeAdmission.admit(source.buffer.rangeDescriptor, against: snapshot) {
            case .failure(let reason):
                publishedState = publishedState.advancingRejected()
                return .rejected(reason)
            case .success:
                break
            }
            // anchor identity must match every source (one frozen anchor per epoch/revision).
            guard anchor.revision == source.buffer.revision, anchor.epoch == source.buffer.epoch else {
                throw PreviewAudioGraphError.anchorIdentityMismatch
            }
            // the source must cover exactly the mix range (no partial/implicit pad).
            guard source.buffer.chunkRange == mixRange else {
                throw PreviewAudioGraphError.sourceRangeMismatch
            }
            guard Int64(source.samples.count) == frameCount else {
                throw PreviewAudioGraphError.sampleCountMismatch(
                    expected: frameCount, got: source.samples.count)
            }

            // mute → contributes silence; gain → linear multiplier (raw / unity) at the DSP boundary.
            if source.buffer.isMuted { continue }
            let gainMultiplier = Float32(source.buffer.gain.raw) / Float32(Self.gainUnityRaw)
            for i in 0..<Int(frameCount) {
                accumulator[i] += source.samples[i] * gainMultiplier
            }
        }

        // 5. Output stage AFTER the sum (D-213 Candidate A); non-finite fails closed (no scheduling).
        var mixed = [Float32]()
        mixed.reserveCapacity(Int(frameCount))
        for s in accumulator {
            mixed.append(try OutputOverloadStage.process(s))
        }

        // 6. Explicit anchor-relative output sample time (no `nil` time anywhere).
        let outputSampleTime = try anchor.scheduledOutputSampleTime(forMixStart: mixRange.start)
        try sink.scheduleMixed(range: mixRange, samples: mixed, at: outputSampleTime)
        publishedState = publishedState.advancing(toScheduled: mixRange)
        return .scheduled
    }
}

/// The outcome of offering one mix to the graph.
public enum ChunkScheduleOutcome: Equatable, Sendable {
    case scheduled
    case rejected(RejectionReason)
}

// MARK: - Real AVFoundation sink (the ONLY AV-importing type)

#if canImport(AVFoundation)

/// The real device sink: one engine-owned `AVAudioEngine` and **one** output `AVAudioPlayerNode`. The
/// canonical software mix already summed and output-staged the sources, so a single output node is
/// correct (no per-source pre-mix saturation). This is the sole AVFoundation surface of Stage E. It does
/// not render the whole project, write a temp file, use `AVMutableComposition`, loop, or auto-resume.
///
/// Each mixed buffer is scheduled at an explicit `AVAudioTime(sampleTime:atRate:)` — never `nil`. Samples
/// are final mixed mono frames; the output node uses a mono format and the mixer fans out to the device.
///
/// The realtime render callback consumes only preallocated buffers the engine already holds; this type
/// performs no I/O / allocation / lock / logging / `Date` inside that callback path — scheduling happens
/// here, outside it.
public final class AVAudioEnginePreviewSink: PreviewAudioOutputSink, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let outputPlayer = AVAudioPlayerNode()
    private var monoFormat: AVAudioFormat?

    public init() {
        engine.attach(outputPlayer)
    }

    public func configure(outputFormat: AudioOutputFormat, route: AudioOutputRoute) throws {
        // `Double` here is ONLY the local AVAudioFormat sample-rate bridge the AV API forces; the
        // canonical sample rate stays the integer `outputFormat.sampleRate`. Not stored as canonical.
        let avSampleRate = Double(outputFormat.sampleRate)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: avSampleRate, channels: 1) else {
            throw PreviewAudioGraphError.outputConfiguredBeforeActivation
        }
        monoFormat = fmt
        engine.connect(outputPlayer, to: engine.mainMixerNode, format: fmt)
    }

    public func scheduleMixed(
        range: AudioSampleRange,
        samples: [Float32],
        at outputSampleTime: Int64
    ) throws {
        guard let fmt = monoFormat else {
            throw PreviewAudioGraphError.scheduledBeforeOutputConfigured
        }
        let frameCount = AVAudioFrameCount(samples.count)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else {
            throw PreviewAudioGraphError.emptyMixRange
        }
        pcm.frameLength = frameCount
        // Final mixed mono frames: one channel, one sample per frame.
        if let channelData = pcm.floatChannelData {
            for frame in 0..<Int(frameCount) {
                channelData[0][frame] = samples[frame]
            }
        }
        let when = AVAudioTime(
            sampleTime: AVAudioFramePosition(outputSampleTime),
            atRate: fmt.sampleRate)
        outputPlayer.scheduleBuffer(pcm, at: when, options: [], completionHandler: nil)
    }
}

#endif
