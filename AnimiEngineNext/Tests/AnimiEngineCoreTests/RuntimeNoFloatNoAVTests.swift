import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage A — guards the runtime control core against floating-point and AVFoundation.
///
/// Mirrors the Slice-002 `Audio/*.swift` sweep: every `Sources/AnimiEngineCore/Runtime/*.swift` file
/// must contain integer/string identity logic only — no `Float`/`Double`/`Decimal`, and no
/// `import AVFoundation`/`import AVFAudio`. The realtime audio-framework boundary is a later slice.
final class RuntimeNoFloatNoAVTests: XCTestCase {

    func testNoFloatingPointOrAVFoundationInRuntimeSources() throws {
        // #filePath = .../AnimiEngineNext/Tests/AnimiEngineCoreTests/RuntimeNoFloatNoAVTests.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile
            .deletingLastPathComponent()   // AnimiEngineCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AnimiEngineNext (package root)
        let runtimeDir = packageRoot
            .appendingPathComponent("Sources/AnimiEngineCore/Runtime", isDirectory: true)

        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: runtimeDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Runtime/*.swift found at \(runtimeDir.path)")

        // Runtime files that MUST be covered by this sweep (Stage A + Stage B).
        let coveredNames = Set(files.map { $0.lastPathComponent })
        for required in [
            "Identities.swift", "CacheArtifactID.swift", "IdentityAllocators.swift",
            "MasterClock.swift", "MasterClockSelector.swift",
            "TransportState.swift", "TransportCommand.swift", "TransportReducer.swift",
            "FrameWorkset.swift", "PublishedFrame.swift", "PublicationGate.swift",
            "FramePlanProvider.swift", "RenderResultSource.swift", "SchedulerSnapshot.swift",
            "AdmissionController.swift", "ScrubSettlePolicy.swift",
            "BoundedQueue.swift", "AudioRangeAdmission.swift", "EngineScheduler.swift",
            "SchedulerDiagnostics.swift",
        ] {
            XCTAssertTrue(coveredNames.contains(required), "sweep does not cover Runtime/\(required)")
        }

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in ["Float", "Double", "Decimal", "import AVFoundation", "import AVFAudio"] {
                XCTAssertFalse(
                    text.contains(banned),
                    "\(file.lastPathComponent) must not reference \(banned) (integer/string identities only)"
                )
            }
        }
    }
}
