import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Stage 0 — Architecture guard baseline for the canonical preview-audio boundary.
///
/// We deleted the rejected *live* decode path from the preview Play path:
///   - `PCMDecoder`
///   - `AVAssetReaderPCMDecoder`
///   - `AppAudioChunkPreparer`
///   - live `AVAssetReader.copyNextSampleBuffer()` inside preview start
///
/// The correct boundary is now:
///   `AudioPlan -> background/prewarmed PCM render cache -> CanonicalAudioRenderPipeline -> PreviewAudioGraph`
///
/// These tests are a tripwire: they fail if any deleted live-decode symbol, the live `AVAssetReader`
/// pull API, or a removed source/test file reference creeps back into the Realtime preview path or the
/// Xcode project, and they pin the production factory + plan source onto `CanonicalAudioRenderPipeline`.
///
/// Scope-disciplined: each test scans ONLY the file/dir it asserts about (no repo-wide grep), strips Swift
/// comments before token scans (so prose that *names* a forbidden symbol does not false-positive), and is
/// deterministic + fast (pure file reads, no shell, no device).
@MainActor
final class CanonicalAudioArchitectureTests: XCTestCase {

    // MARK: - Helpers

    /// Repo root resolved from this file: `<repo>/AnimiApp/Tests/CanonicalAudioArchitectureTests.swift`
    /// → up three components (Tests → AnimiApp → repo root). No shell, no CWD assumptions.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../AnimiApp/Tests
            .deletingLastPathComponent()   // .../AnimiApp
            .deletingLastPathComponent()   // repo root
            .standardizedFileURL
    }

    /// Read a repo-relative file as UTF-8. Fails the test (rather than crashing) if it is missing — a moved
    /// guarded file should surface as a clear failure, not a silent pass.
    private func read(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = repoRoot().appendingPathComponent(relativePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("guarded file is missing: \(relativePath)", file: file, line: line)
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// List `.swift` files directly under a repo-relative directory (non-recursive is enough — the Realtime
    /// boundary is flat). Fails if the directory is missing.
    private func swiftFiles(inDirectory relativeDir: String,
                            file: StaticString = #filePath, line: UInt = #line) throws -> [URL] {
        let dir = repoRoot().appendingPathComponent(relativeDir).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            XCTFail("guarded directory is missing: \(relativeDir)", file: file, line: line)
            return []
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return contents.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// Strip Swift line comments (`// ...`) and block comments (`/* ... */`) so that documentation prose
    /// that *mentions* a forbidden symbol (e.g. "AVAssetReader is not part of this path") does not count as
    /// a real reference. String-literal contents are intentionally left intact: a real `AVAssetReader(` or
    /// deleted type name should never legitimately appear inside a preview-path string literal, and keeping
    /// literals avoids a brittle mini-parser. Simple, single-pass, deterministic.
    private func stripSwiftComments(_ source: String) -> String {
        var out = String()
        out.reserveCapacity(source.count)
        var inLineComment = false
        var inBlockComment = false
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = (i + 1) < chars.count ? chars[i + 1] : nil
            if inLineComment {
                if c == "\n" { inLineComment = false; out.append(c) }
                i += 1
                continue
            }
            if inBlockComment {
                if c == "*", next == "/" { inBlockComment = false; i += 2; continue }
                // Preserve newlines so line numbers / structure stay roughly stable; drop other content.
                if c == "\n" { out.append(c) }
                i += 1
                continue
            }
            if c == "/", next == "/" { inLineComment = true; i += 2; continue }
            if c == "/", next == "*" { inBlockComment = true; i += 2; continue }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Assert that NONE of `tokens` appears in `source`. Reports every offending token for one-shot triage.
    private func assertNoTokens(_ tokens: [String], in source: String, label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let hits = tokens.filter { source.contains($0) }
        XCTAssertTrue(hits.isEmpty,
            "\(label): forbidden token(s) present after comment-strip: \(hits.joined(separator: ", "))",
            file: file, line: line)
    }

    /// Assert that ALL of `tokens` appear in `source`.
    private func assertContainsAll(_ tokens: [String], in source: String, label: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let missing = tokens.filter { !source.contains($0) }
        XCTAssertTrue(missing.isEmpty,
            "\(label): expected token(s) missing: \(missing.joined(separator: ", "))",
            file: file, line: line)
    }

    /// Concatenate the comment-stripped source of every `.swift` file in a repo-relative directory, excluding
    /// any whose last path component is in `excludingFiles` (the sanctioned AV boundary allow-list).
    private func strippedSource(ofDirectory relativeDir: String, excluding excludingFiles: Set<String> = []) throws -> String {
        let files = try swiftFiles(inDirectory: relativeDir)
        var combined = String()
        for url in files where !excludingFiles.contains(url.lastPathComponent) {
            let raw = try String(contentsOf: url, encoding: .utf8)
            combined += "\n// FILE: \(url.lastPathComponent)\n"   // marker is in a comment-stripped pass below
            combined += stripSwiftComments(raw)
        }
        // The injected FILE markers above are line comments — strip once more so they cannot match a token.
        return stripSwiftComments(combined)
    }

    /// The SINGLE sanctioned AVFoundation boundary file in the Realtime preview path (Stage 3). Every other
    /// file in `Realtime/` must stay AVFoundation-free.
    private let avBoundaryFile = "AVFoundationPCMAssetDecoder.swift"

    private let realtimeDir = "AnimiApp/Sources/EditorRuntime/Realtime"

    // MARK: - 1. No deleted live-decoder TYPE names in the Realtime preview path

    func testRealtimePreviewPathDoesNotReferenceDeletedLiveDecoderTypes() throws {
        let src = try strippedSource(ofDirectory: realtimeDir)
        assertNoTokens(
            ["PCMDecoder",
             "AVAssetReaderPCMDecoder",
             "AppAudioChunkPreparer",
             "PCMDecodeRequest",
             "decodeNotImplemented",
             "decodeTimedOut"],
            in: src,
            label: "Realtime preview path references a deleted live-decoder type")
    }

    // MARK: - 2. No live AVAssetReader pull API in the Realtime preview path (EXCEPT the AV boundary file)

    /// Stage 3: the AVFoundation DECODE API (`AVAssetReader(` / `AVAssetReaderTrackOutput` /
    /// `AVAssetReaderAudioMixOutput` / `copyNextSampleBuffer` / `cancelReading`) is allowed ONLY inside
    /// `AVFoundationPCMAssetDecoder.swift` (the sanctioned background-decode boundary). Everywhere else in
    /// `Realtime/` — especially the controller, factory, and play path — it is banned.
    ///
    /// NOTE: `import AVFoundation` itself is NOT banned across Realtime — the session adapter / event mapping
    /// legitimately use `AVAudioSession` / `AVAudioEngine` (session/route, NOT decode). Confinement is on the
    /// DECODE API specifically; `import AVFoundation`-only-in-the-boundary is asserted for the decode-free
    /// renderer/protocol files by `testAVFoundationDecodeConfinedToBoundaryFile`.
    func testRealtimePreviewPathDoesNotCallLiveAVAssetReader() throws {
        // Exclude exactly the one sanctioned AV boundary file; scan everything else in Realtime/.
        let src = try strippedSource(ofDirectory: realtimeDir, excluding: [avBoundaryFile])
        // Note: `AVAssetReader(` (with the open paren) targets the constructor, so the documented phrase
        // "AVAssetReader may be used by a future background renderer" (a bare word in a comment, already
        // stripped) cannot match even if it survived stripping.
        assertNoTokens(
            ["AVAssetReader(",
             "AVAssetReaderTrackOutput",
             "AVAssetReaderAudioMixOutput",
             "copyNextSampleBuffer",
             "cancelReading",
             "import AVFAudio"],
            in: src,
            label: "Realtime preview path (excluding the AV boundary file) uses the live AVFoundation decode API")
    }

    // MARK: - 2b. Stage 3: the AV boundary file IS the only place AVFoundation decode lives

    func testAVFoundationDecodeConfinedToBoundaryFile() throws {
        // The boundary file itself MUST be present and MUST own the AV decode API.
        let boundary = stripSwiftComments(try read("\(realtimeDir)/\(avBoundaryFile)"))
        assertContainsAll(
            ["import AVFoundation",
             "AVAssetReader(",
             "copyNextSampleBuffer",
             "cancelReading"],
            in: boundary,
            label: "the sanctioned AV boundary file must own the bounded AVAssetReader decode + hard cancel")
        // The decode-free renderer + protocol files must be AVFoundation-free.
        for file in ["BackgroundCanonicalPCMRenderer.swift", "CanonicalPCMAssetDecoder.swift"] {
            let stripped = stripSwiftComments(try read("\(realtimeDir)/\(file)"))
            assertNoTokens(
                ["import AVFoundation", "import AVFAudio", "AVAssetReader(", "copyNextSampleBuffer", "cancelReading"],
                in: stripped,
                label: "\(file) must be AVFoundation-free (decode is confined to \(avBoundaryFile))")
        }
    }

    // MARK: - 2c. Stage 3: controller + factory remain free of AVFoundation decode API

    func testControllerAndFactoryFreeOfAVDecode() throws {
        for file in ["CanonicalPreviewAudioController.swift", "CanonicalPreviewAudioControllerFactory.swift"] {
            let stripped = stripSwiftComments(try read("\(realtimeDir)/\(file)"))
            assertNoTokens(
                ["AVAssetReader(", "copyNextSampleBuffer", "cancelReading"],
                in: stripped,
                label: "\(file) must not call the AVFoundation decode API (Stage 4 owns wiring, not decode)")
        }
    }

    // MARK: - 3. Xcode project no longer references deleted live-decoder files

    func testXcodeProjectDoesNotReferenceDeletedLiveDecoderFiles() throws {
        // pbxproj is not Swift; scan it raw (no comment-strip — file references are not Swift comments).
        let pbx = try read("AnimiApp/AnimiApp.xcodeproj/project.pbxproj")
        assertNoTokens(
            ["PCMDecoder.swift",
             "AVAssetReaderPCMDecoder.swift",
             "AppAudioChunkPreparer.swift",
             "AVAssetReaderPCMDecoderTests.swift",
             "AppAudioChunkPreparerTests.swift",
             "CanonicalPreviewAudioChainTests.swift"],
            in: pbx,
            label: "project.pbxproj references a deleted live-decoder file")
    }

    // MARK: - 3b. Stage 2 cache-backed pipeline is present, conforms, and stays decode-free

    func testCachedCanonicalAudioRenderPipelineIsPresentAndDecodeFree() throws {
        let pipeline = "\(realtimeDir)/CachedCanonicalAudioRenderPipeline.swift"
        let stripped = stripSwiftComments(try read(pipeline))
        // Required: it IS a CanonicalAudioRenderPipeline routing through the PCM render cache.
        assertContainsAll(
            ["CanonicalAudioRenderPipeline",
             "CanonicalPCMRenderCache",
             "cache.chunk(for: request, key: key)"],
            in: stripped,
            label: "Stage 2 cache-backed pipeline must route the request through the PCM render cache")
        // Banned: no deleted live-decoder types, no AVFoundation decode.
        assertNoTokens(
            ["PCMDecoder",
             "AVAssetReaderPCMDecoder",
             "AppAudioChunkPreparer",
             "AVAssetReader(",
             "copyNextSampleBuffer",
             "import AVFoundation",
             "import AVFAudio"],
            in: stripped,
            label: "Stage 2 cache-backed pipeline must stay decode-free")
    }

    // MARK: - 4. Production factory depends on CanonicalAudioRenderPipeline (not a live decoder)

    func testFactoryDependsOnCanonicalAudioRenderPipeline() throws {
        let factory = "\(realtimeDir)/CanonicalPreviewAudioControllerFactory.swift"
        let stripped = stripSwiftComments(try read(factory))
        assertContainsAll(
            ["CanonicalAudioRenderPipeline",
             "renderPipeline.prepareInitialPreroll"],
            in: stripped,
            label: "factory must depend on the canonical render pipeline")
        assertNoTokens(
            ["AVAssetReaderPCMDecoder",
             "AppAudioChunkPreparer"],
            in: stripped,
            label: "factory must not reference a deleted live decoder")
    }

    // MARK: - 4b. Stage 4: production factory builds the REAL cached render pipeline (not the placeholder)

    func testProductionFactoryBuildsRealCachedRenderPipeline() throws {
        let factory = "\(realtimeDir)/CanonicalPreviewAudioControllerFactory.swift"
        let stripped = stripSwiftComments(try read(factory))
        // The production builder must assemble the real Stage 1/2/3 stack.
        assertContainsAll(
            ["AVFoundationPCMAssetDecoder(",
             "BackgroundCanonicalPCMRenderer(",
             "CanonicalPCMRenderCache.make(",
             "CachedCanonicalAudioRenderPipeline("],
            in: stripped,
            label: "production factory must build the real cached PCM render pipeline")
        // `UnavailableCanonicalAudioRenderPipeline` may survive ONLY as the fail-closed catch fallback
        // (a bare `renderPipeline = UnavailableCanonicalAudioRenderPipeline()` assignment). It must NOT be a
        // DEFAULT PARAMETER value (the type-annotated `: CanonicalAudioRenderPipeline = Unavailable...()` form),
        // which is what made the placeholder the production default before Stage 4.
        assertNoTokens(
            ["CanonicalAudioRenderPipeline = UnavailableCanonicalAudioRenderPipeline()"],
            in: stripped,
            label: "Unavailable placeholder must not be the production DEFAULT render pipeline parameter")
        // The factory itself must never touch the AV decode API (that is confined to the boundary file).
        assertNoTokens(
            ["AVAssetReader(", "copyNextSampleBuffer", "cancelReading",
             "AVAssetReaderTrackOutput", "AVAssetReaderAudioMixOutput"],
            in: stripped,
            label: "factory must not contain the AVFoundation decode API")
    }

    // MARK: - 4c. Stage 4: the preview controller never touches the AV decode API

    func testPreviewControllerFreeOfAVDecodeAPI() throws {
        let controller = "\(realtimeDir)/CanonicalPreviewAudioController.swift"
        let stripped = stripSwiftComments(try read(controller))
        assertNoTokens(
            ["AVAssetReader(", "copyNextSampleBuffer", "cancelReading",
             "AVAssetReaderTrackOutput", "AVAssetReaderAudioMixOutput"],
            in: stripped,
            label: "preview controller must not contain the AVFoundation decode API")
    }

    // MARK: - 5. Unavailable renderer FAILS CLOSED for a non-empty plan (no silent silence)

    func testUnavailableRendererFailsClosedForNonEmptyPlan() async throws {
        let plan = try Self.nonEmptyMusicPlan()
        XCTAssertFalse(plan.segments.isEmpty, "precondition: plan must carry real audio")

        let request = CanonicalAudioRenderRequest(
            plan: plan,
            revision: Self.revision(1),
            epoch: Self.epoch(1),
            anchor: PreviewAudioScheduleAnchor(
                revision: Self.revision(1), epoch: Self.epoch(1),
                projectSample: 0, outputSampleTime: 0),
            range: plan.sampleInterval,
            resolvedSourcesByID: ["s0": CanonicalResolvedAudioSource(url: URL(fileURLWithPath: "/tmp/none"))])

        let renderer = UnavailableCanonicalAudioRenderPipeline()
        do {
            _ = try await renderer.prepareInitialPreroll(request, onDiagnostic: nil)
            XCTFail("non-empty plan must NOT silently render to []; it must throw fail-closed")
        } catch let error as AppRealtimeAudioIntegrationError {
            guard case .audioRenderPipelineUnavailable = error else {
                return XCTFail("expected .audioRenderPipelineUnavailable, got \(error)")
            }
            // Pass: a non-empty plan fails visibly instead of becoming silence.
        }
    }

    // MARK: - 6. Unavailable renderer ALLOWS an empty plan as legitimate silence

    func testUnavailableRendererAllowsEmptyPlanAsSilence() async throws {
        let emptyInterval = try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 8 * AudioSampleGrid.ticksPerSample)))
        let emptyPlan = AudioPlan(sampleInterval: emptyInterval, segments: [])
        XCTAssertTrue(emptyPlan.segments.isEmpty, "precondition: genuinely empty plan")

        let request = CanonicalAudioRenderRequest(
            plan: emptyPlan,
            revision: Self.revision(2),
            epoch: Self.epoch(2),
            anchor: PreviewAudioScheduleAnchor(
                revision: Self.revision(2), epoch: Self.epoch(2),
                projectSample: 0, outputSampleTime: 0),
            range: emptyInterval,
            resolvedSourcesByID: [:])

        let renderer = UnavailableCanonicalAudioRenderPipeline()
        let sources = try await renderer.prepareInitialPreroll(request, onDiagnostic: nil)
        XCTAssertTrue(sources.isEmpty,
            "an empty plan is legitimate silence — the unavailable renderer returns [] (no throw)")
    }

    // MARK: - 7. Canonical plan source still builds video-original + music (and no deleted decoders)

    func testCanonicalPlanSourceStillBuildsVideoOriginalAndMusic() throws {
        let planSource = "\(realtimeDir)/RuntimeCanonicalAudioPlanSource.swift"
        let stripped = stripSwiftComments(try read(planSource))
        // Structural confirmation that the canonical build chain is intact (deep behavioural coverage lives
        // in RuntimeCanonicalAudioPlanSourceTests / VideoOriginalAudioPlanTests — not duplicated here).
        assertContainsAll(
            ["AppVideoOriginalAudioBridge",
             "AudioEvaluationWindowBuilder.build",
             "AudioEvaluator.evaluate"],
            in: stripped,
            label: "canonical plan source must keep the video-original + evaluator build chain")
        assertNoTokens(
            ["PCMDecoder",
             "AVAssetReaderPCMDecoder",
             "AppAudioChunkPreparer"],
            in: stripped,
            label: "canonical plan source must not reference a deleted live decoder")
    }

    // MARK: - Fixtures (public initializers only; no @testable engine access needed)

    // `ProjectRevision(raw:)` / `PlaybackEpoch(raw:)` are engine-internal inits (not reachable without
    // `@testable import AnimiEngineCore`). Mint via the PUBLIC deterministic allocators instead — the same
    // public path production + `FixtureRenderPipeline` use, so no engine-internal access is required.
    private static func revision(_ raw: Int64) -> ProjectRevision {
        var alloc = MonotonicRevisionAllocator(start: raw)
        return alloc.next()
    }

    private static func epoch(_ raw: Int64) -> PlaybackEpoch {
        var alloc = MonotonicEpochAllocator(start: raw)
        return alloc.next()
    }

    /// A minimal but genuinely non-empty music plan (one segment), mirroring the fixture shape proven in
    /// `CanonicalCutoverBypassTests.musicPlan()`.
    private static func nonEmptyMusicPlan() throws -> AudioPlan {
        let interval = try AudioSampleRange.from(projectTicks:
            ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 8 * AudioSampleGrid.ticksPerSample)))
        let seg = AudioSegmentPlan(
            clipID: try AudioClipID("c0"),
            sourceID: try AudioSourceID("s0"),
            trackID: try AudioTrackID("t0"),
            role: .music,
            destinationSamples: interval,
            sourceStart: .zero,
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(
                start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 1)),
            isMuted: false,
            gain: .unity,
            sourceSampleRate: 48_000,
            channelLayout: .mono,
            streamIdentity: try AudioStreamIdentity("stream-0"),
            sceneID: nil)
        return AudioPlan(sampleInterval: interval, segments: [seg])
    }
}
