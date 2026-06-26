import XCTest

/// Slice 3.5 — deterministic media corpus contract (roadmap §5).
///
/// Pure, device-free, AVFoundation-free verification of the committed corpus under
/// `Docs/AnimiEngineNext/media-corpus/`:
///   * the corpus manifest + the deterministic generator both exist;
///   * every committed asset file exists with the expected byte count;
///   * every committed asset's SHA-256 matches the manifest (byte-stability);
///   * the audio WAV headers parse and their sample-rate/channels/duration match
///     the manifest (safely inspectable canonical PCM16 metadata);
///   * the required corpus shape is present (44.1/48/96 kHz tones, silent audio,
///     silent video, known-audio video, corrupt + missing, 6/10/20 stress,
///     transition-overlap).
///
/// This test reads files from the repo working tree via `#filePath` (the same
/// pattern as `RuntimeNoFloatNoAVTests`); it needs no bundled package resource and
/// therefore no `Package.swift` change. It runs no encoder, opens no `AVAsset`,
/// and touches no device/realtime code.
final class MediaCorpusManifestTests: XCTestCase {

    // .../AnimiEngineNext/Tests/AnimiEngineCoreTests/MediaCorpusManifestTests.swift
    // → repo root is four directories up from the package root.
    private func corpusRoot() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // AnimiEngineCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AnimiEngineNext
            .deletingLastPathComponent()   // repo root
        return repoRoot
            .appendingPathComponent("Docs/AnimiEngineNext/media-corpus", isDirectory: true)
    }

    private func loadManifest() throws -> [String: Any] {
        let url = corpusRoot().appendingPathComponent("corpus-manifest.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any], "corpus-manifest.json is not a JSON object")
    }

    func testManifestAndGeneratorExist() throws {
        let root = corpusRoot()
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("corpus-manifest.json").path),
                      "corpus-manifest.json missing")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("generate_corpus.py").path),
                      "generate_corpus.py (deterministic generator) missing")
    }

    func testEveryAssetExistsWithExpectedBytesAndHash() throws {
        let root = corpusRoot()
        let manifest = try loadManifest()
        let assets = try XCTUnwrap(manifest["assets"] as? [[String: Any]], "manifest.assets missing")
        XCTAssertFalse(assets.isEmpty, "manifest declares no assets")

        let declaredCount = try XCTUnwrap(manifest["assetCount"] as? Int)
        XCTAssertEqual(declaredCount, assets.count, "assetCount disagrees with assets array")

        for asset in assets {
            let relPath = try XCTUnwrap(asset["path"] as? String, "asset missing path")
            let expectedSHA = try XCTUnwrap(asset["sha256"] as? String, "\(relPath) missing sha256")
            let expectedBytes = try XCTUnwrap(asset["byteCount"] as? Int, "\(relPath) missing byteCount")

            let fileURL = root.appendingPathComponent(relPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                          "committed asset missing: \(relPath)")
            let data = try Data(contentsOf: fileURL)
            XCTAssertEqual(data.count, expectedBytes, "\(relPath) byte count drift")
            XCTAssertEqual(Self.sha256Hex(data), expectedSHA, "\(relPath) SHA-256 drift (not byte-stable)")
        }
    }

    func testAudioWavMetadataMatchesManifest() throws {
        let root = corpusRoot()
        let manifest = try loadManifest()
        let assets = try XCTUnwrap(manifest["assets"] as? [[String: Any]])
        let audio = assets.filter { ($0["category"] as? String) == "audio" }
        // 4 standalone tones/silence + 1 per-fixture PCM track for video_with_audio.
        XCTAssertEqual(audio.count, 5, "expected 5 audio assets (3 tones + silent + known-audio track)")

        for asset in audio {
            let relPath = try XCTUnwrap(asset["path"] as? String)
            let expectedRate = try XCTUnwrap(asset["sampleRate"] as? Int, "\(relPath) missing sampleRate")
            let expectedChannels = try XCTUnwrap(asset["channels"] as? Int)
            let expectedSamples = try XCTUnwrap(asset["sampleCount"] as? Int)

            let data = try Data(contentsOf: root.appendingPathComponent(relPath))
            let wav = try Self.parseCanonicalPCM16WAV(data, label: relPath)
            XCTAssertEqual(wav.sampleRate, expectedRate, "\(relPath) WAV sampleRate mismatch")
            XCTAssertEqual(wav.channels, expectedChannels, "\(relPath) WAV channels mismatch")
            XCTAssertEqual(wav.bitsPerSample, 16, "\(relPath) not PCM16")
            XCTAssertEqual(wav.frameCount, expectedSamples, "\(relPath) sample count mismatch")
        }
    }

    func testRequiredCorpusShapeIsPresent() throws {
        let manifest = try loadManifest()
        let assets = try XCTUnwrap(manifest["assets"] as? [[String: Any]])
        let paths = Set(assets.compactMap { $0["path"] as? String })

        let required = [
            "audio/tone_44100hz.wav", "audio/tone_48000hz.wav", "audio/tone_96000hz.wav",
            "audio/silent_48000hz.wav",
            // Real committed video fixtures (frame sequences + the known-audio PCM track).
            "video/silent_video/frame_000.ppm", "video/silent_video/frame_005.ppm",
            "video/video_with_audio/frame_000.ppm", "video/video_with_audio/frame_005.ppm",
            "video/video_with_audio/audio.wav",
            "descriptors/silent_video.json", "descriptors/video_with_audio.json",
            "descriptors/corrupt_media.json", "descriptors/corrupt_media.bin",
            "descriptors/missing_media.json",
            "projects/stress_6_video.json", "projects/stress_10_video.json",
            "projects/stress_20_video.json", "projects/transition_overlap.json",
        ]
        for r in required { XCTAssertTrue(paths.contains(r), "required corpus asset absent: \(r)") }
    }

    /// The silent / known-audio video fixtures are REAL committed media (deterministic PPM frame
    /// sequences + a committed PCM track), not just descriptors. Verify their actual on-disk shape.
    func testRealVideoFrameSequenceFixtures() throws {
        let root = corpusRoot()
        let manifest = try loadManifest()
        let assets = try XCTUnwrap(manifest["assets"] as? [[String: Any]])

        for fixture in ["silent_video", "video_with_audio"] {
            let frames = assets.filter {
                ($0["category"] as? String) == "videoFrame" && ($0["fixture"] as? String) == fixture
            }
            XCTAssertEqual(frames.count, 6, "\(fixture) must have 6 committed frames")

            // Frame indices 0...5 present and contiguous.
            let indices = Set(frames.compactMap { $0["frameIndex"] as? Int })
            XCTAssertEqual(indices, Set(0..<6), "\(fixture) frame indices not contiguous 0..5")

            for f in frames {
                let relPath = try XCTUnwrap(f["path"] as? String)
                let w = try XCTUnwrap(f["width"] as? Int)
                let h = try XCTUnwrap(f["height"] as? Int)
                let data = try Data(contentsOf: root.appendingPathComponent(relPath))
                let dims = try Self.parsePPMP6Header(data, label: relPath)
                XCTAssertEqual(dims.width, w, "\(relPath) PPM width != manifest")
                XCTAssertEqual(dims.height, h, "\(relPath) PPM height != manifest")
                // Body must hold exactly width*height*3 RGB bytes after the header.
                XCTAssertEqual(data.count - dims.headerLength, w * h * 3,
                               "\(relPath) PPM body size wrong (not raw RGB)")
            }
        }

        // The known-audio fixture's committed PCM track: real 48 kHz PCM16, duration == frames/fps.
        let audioData = try Data(contentsOf: root.appendingPathComponent("video/video_with_audio/audio.wav"))
        let wav = try Self.parseCanonicalPCM16WAV(audioData, label: "video_with_audio/audio.wav")
        XCTAssertEqual(wav.sampleRate, 48000)
        XCTAssertEqual(wav.channels, 1)
        XCTAssertEqual(wav.bitsPerSample, 16)
        XCTAssertEqual(wav.frameCount, 48000, "audio.wav must be exactly 1.0 s (6 frames / 6 fps)")

        // The descriptors must point at the real frame dirs + flag the encoded clip as derived.
        for (file, expectAudio) in [("descriptors/silent_video.json", false),
                                    ("descriptors/video_with_audio.json", true)] {
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: try Data(contentsOf: root.appendingPathComponent(file))) as? [String: Any])
            XCTAssertEqual(obj["frameCount"] as? Int, 6, "\(file) frameCount")
            XCTAssertEqual(obj["hasAudioTrack"] as? Bool, expectAudio, "\(file) hasAudioTrack")
            XCTAssertEqual(obj["encodedArtifact"] as? String, "derivedForSlice4DeviceGate",
                           "\(file) must mark encoded clip as derived, not the canonical fixture")
            XCTAssertNotNil(obj["framesDir"] as? String, "\(file) must reference its real frame dir")
        }
    }

    func testStressProjectDescriptorLayerCounts() throws {
        let root = corpusRoot()
        for (file, expected) in [
            ("projects/stress_6_video.json", 6),
            ("projects/stress_10_video.json", 10),
            ("projects/stress_20_video.json", 20),
        ] {
            let data = try Data(contentsOf: root.appendingPathComponent(file))
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(obj["videoLayerCount"] as? Int, expected, "\(file) layer count")
            let layers = try XCTUnwrap(obj["layers"] as? [[String: Any]])
            XCTAssertEqual(layers.count, expected, "\(file) layers array size")
        }
    }

    // MARK: - Canonical PCM16 WAV parse (header only; no audio framework)

    private struct WAVInfo { let sampleRate: Int; let channels: Int; let bitsPerSample: Int; let frameCount: Int }

    private static func parseCanonicalPCM16WAV(_ d: Data, label: String) throws -> WAVInfo {
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1])<<8 | Int(d[o+2])<<16 | Int(d[o+3])<<24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1])<<8 }
        try XCTSkipIf(d.count < 44, "\(label) too small to be a WAV")
        XCTAssertEqual(Array(d[0..<4]), Array("RIFF".utf8), "\(label) missing RIFF")
        XCTAssertEqual(Array(d[8..<12]), Array("WAVE".utf8), "\(label) missing WAVE")
        XCTAssertEqual(Array(d[12..<16]), Array("fmt ".utf8), "\(label) missing fmt ")
        let audioFormat = u16(20)
        XCTAssertEqual(audioFormat, 1, "\(label) not linear PCM")
        let channels = u16(22)
        let sampleRate = u32(24)
        let bits = u16(34)
        XCTAssertEqual(Array(d[36..<40]), Array("data".utf8), "\(label) missing data chunk")
        let dataBytes = u32(40)
        let bytesPerFrame = max(1, channels * bits / 8)
        return WAVInfo(sampleRate: sampleRate, channels: channels, bitsPerSample: bits,
                       frameCount: dataBytes / bytesPerFrame)
    }

    // MARK: - PPM P6 header parse (no image framework)

    private struct PPMDims { let width: Int; let height: Int; let headerLength: Int }

    /// Parses a binary PPM P6 header: "P6\n<w> <h>\n255\n". Returns dims + header byte length.
    private static func parsePPMP6Header(_ d: Data, label: String) throws -> PPMDims {
        let bytes = [UInt8](d)
        try XCTSkipIf(bytes.count < 11, "\(label) too small to be a PPM")
        XCTAssertEqual(bytes[0], UInt8(ascii: "P"), "\(label) missing P6 magic")
        XCTAssertEqual(bytes[1], UInt8(ascii: "6"), "\(label) missing P6 magic")
        // Tokenize the ASCII header: magic, width, height, maxval — each whitespace-separated.
        var i = 2
        func skipWS() { while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0a || bytes[i] == 0x0d || bytes[i] == 0x09 { i += 1 } }
        func readInt() -> Int { var v = 0; while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { v = v * 10 + Int(bytes[i] - 0x30); i += 1 }; return v }
        skipWS(); let w = readInt()
        skipWS(); let h = readInt()
        skipWS(); let maxval = readInt()
        XCTAssertEqual(maxval, 255, "\(label) PPM maxval must be 255")
        // Exactly one whitespace byte follows maxval before the binary body (our generator uses '\n').
        XCTAssertTrue(i < bytes.count, "\(label) PPM has no body")
        let headerLen = i + 1
        return PPMDims(width: w, height: h, headerLength: headerLen)
    }

    // MARK: - SHA-256 (no CryptoKit dependency; small, deterministic, test-only)

    private static func sha256Hex(_ data: Data) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }

        var w = [UInt32](repeating: 0, count: 64)
        var off = 0
        while off < msg.count {
            for i in 0..<16 {
                let j = off + i * 4
                w[i] = UInt32(msg[j]) << 24 | UInt32(msg[j+1]) << 16 | UInt32(msg[j+2]) << 8 | UInt32(msg[j+3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], dd = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = dd &+ t1; dd = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ dd
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            off += 64
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
