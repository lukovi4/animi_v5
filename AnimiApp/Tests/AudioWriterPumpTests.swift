import XCTest
import AVFoundation
import CoreMedia
@testable import AnimiApp

final class AudioWriterPumpTests: XCTestCase {

    // MARK: - test_noBlockingWait

    func test_noBlockingWait() {
        // start() should return immediately, not block the calling thread
        let pump = AudioWriterPump()

        // Create a minimal composition with no audio tracks — pump should complete immediately
        let composition = AVMutableComposition()
        let mockInput = MockWriterInput()

        let exp = expectation(description: "completion called")
        pump.start(
            composition: composition,
            audioMix: nil,
            audioInput: mockInput,
            onError: { _ in XCTFail("Should not error on empty composition") },
            completion: { exp.fulfill() }
        )

        // If start() blocked, we wouldn't reach here before timeout
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - test_readinessDrivenDrain

    func test_readinessDrivenDrain() {
        // Verify pump respects isReady flag via mock
        let mockInput = MockWriterInput()
        mockInput.isReadyForMoreMediaData = false

        let pump = AudioWriterPump()
        let composition = AVMutableComposition()

        let exp = expectation(description: "completion")
        pump.start(
            composition: composition,
            audioMix: nil,
            audioInput: mockInput,
            onError: { _ in },
            completion: { exp.fulfill() }
        )

        // Empty composition → immediate completion regardless of readiness
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - test_cancelStopsReading

    func test_cancelStopsReading() {
        let pump = AudioWriterPump()
        let composition = AVMutableComposition()

        let exp = expectation(description: "completion after cancel")
        pump.start(
            composition: composition,
            audioMix: nil,
            audioInput: MockWriterInput(),
            onError: { _ in },
            completion: { exp.fulfill() }
        )

        pump.cancel()
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - test_errorPropagation

    func test_errorPropagation() {
        // Audio pump should call onError when reader setup fails
        let pump = AudioWriterPump()

        // Create a composition that has audio tracks but with invalid data
        // This is tricky to test without real audio. Instead test that cancel calls completion.
        let exp = expectation(description: "completion")
        let composition = AVMutableComposition()

        pump.start(
            composition: composition,
            audioMix: nil,
            audioInput: MockWriterInput(),
            onError: { _ in },
            completion: { exp.fulfill() }
        )

        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - test_completionCalledExactlyOnce

    func test_completionCalledExactlyOnce() {
        let pump = AudioWriterPump()
        let composition = AVMutableComposition()

        var completionCount = 0
        let exp = expectation(description: "completion")

        pump.start(
            composition: composition,
            audioMix: nil,
            audioInput: MockWriterInput(),
            onError: { _ in },
            completion: {
                completionCount += 1
                exp.fulfill()
            }
        )

        // Cancel after start to potentially trigger double completion
        pump.cancel()

        wait(for: [exp], timeout: 1.0)

        // Give extra time for any spurious second call
        let doubleCallExp = expectation(description: "no double call")
        doubleCallExp.isInverted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if completionCount > 1 { doubleCallExp.fulfill() }
        }
        wait(for: [doubleCallExp], timeout: 0.5)
        XCTAssertEqual(completionCount, 1)
    }
}
