import XCTest
import AVFoundation
import CoreMedia
@testable import AnimiApp

// MARK: - Mock Types

class MockWriterInput: WriterInputScheduling {
    var isReadyForMoreMediaData = true
    var finishedCalled = false
    var appendedBuffers: [CMSampleBuffer] = []
    private var readyCallback: (() -> Void)?
    private var callbackQueue: DispatchQueue?

    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        callbackQueue = queue
        readyCallback = block
        if isReadyForMoreMediaData {
            queue.async { block() }
        }
    }

    func markAsFinished() {
        finishedCalled = true
    }

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        appendedBuffers.append(sampleBuffer)
        return true
    }

    func simulateReady() {
        isReadyForMoreMediaData = true
        if let cb = readyCallback, let q = callbackQueue {
            q.async { cb() }
        }
    }
}

class MockPixelBufferAdaptor: PixelBufferAppending {
    var appendedFrames: [(CVPixelBuffer, CMTime)] = []
    var shouldFail = false

    func append(_ pixelBuffer: CVPixelBuffer, withPresentationTime time: CMTime) -> Bool {
        guard !shouldFail else { return false }
        appendedFrames.append((pixelBuffer, time))
        return true
    }
}

// MARK: - Tests

final class VideoWriterPumpTests: XCTestCase {

    private func makeTestPixelBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16,
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        return pixelBuffer!
    }

    // MARK: - test_enqueueBeforeReadiness

    func test_enqueueBeforeReadiness() {
        let input = MockWriterInput()
        input.isReadyForMoreMediaData = false

        let adaptor = MockPixelBufferAdaptor()
        let queue = DispatchQueue(label: "test.pump")
        let pump = VideoWriterPump(input: input, adaptor: adaptor, queue: queue, onError: { _ in })
        pump.start()

        let exp = expectation(description: "all frames appended")
        exp.expectedFulfillmentCount = 3

        for i in 0..<3 {
            let pb = makeTestPixelBuffer()
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            pump.enqueue(pb, presentationTime: pts) { exp.fulfill() }
        }

        // Frames should not be appended yet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(adaptor.appendedFrames.count, 0)
            input.simulateReady()
        }

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(adaptor.appendedFrames.count, 3)
    }

    // MARK: - test_orderedAppend

    func test_orderedAppend() {
        let input = MockWriterInput()
        let adaptor = MockPixelBufferAdaptor()
        let queue = DispatchQueue(label: "test.pump")
        let pump = VideoWriterPump(input: input, adaptor: adaptor, queue: queue, onError: { _ in })
        pump.start()

        let exp = expectation(description: "frames appended")
        exp.expectedFulfillmentCount = 3

        for i in 0..<3 {
            let pb = makeTestPixelBuffer()
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            pump.enqueue(pb, presentationTime: pts) { exp.fulfill() }
        }

        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(adaptor.appendedFrames.count, 3)
        for (idx, (_, time)) in adaptor.appendedFrames.enumerated() {
            XCTAssertEqual(time.value, CMTimeValue(idx))
        }
    }

    // MARK: - test_completionCalledAfterAppend

    func test_completionCalledAfterAppend() {
        let input = MockWriterInput()
        let adaptor = MockPixelBufferAdaptor()
        let queue = DispatchQueue(label: "test.pump")
        let pump = VideoWriterPump(input: input, adaptor: adaptor, queue: queue, onError: { _ in })
        pump.start()

        var completionOrder: [Int] = []
        let exp = expectation(description: "completions")
        exp.expectedFulfillmentCount = 3

        for i in 0..<3 {
            let pb = makeTestPixelBuffer()
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            pump.enqueue(pb, presentationTime: pts) {
                completionOrder.append(i)
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(completionOrder, [0, 1, 2])
    }

    // MARK: - test_finishAfterDrain

    func test_finishAfterDrain() {
        let input = MockWriterInput()
        let adaptor = MockPixelBufferAdaptor()
        let queue = DispatchQueue(label: "test.pump")
        let pump = VideoWriterPump(input: input, adaptor: adaptor, queue: queue, onError: { _ in })
        pump.start()

        let appendExp = expectation(description: "frames appended")
        appendExp.expectedFulfillmentCount = 2
        let finishExp = expectation(description: "finished")

        for i in 0..<2 {
            let pb = makeTestPixelBuffer()
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            pump.enqueue(pb, presentationTime: pts) { appendExp.fulfill() }
        }

        pump.finishEnqueuing {
            finishExp.fulfill()
        }

        wait(for: [appendExp, finishExp], timeout: 2.0)
        XCTAssertTrue(input.finishedCalled)
        XCTAssertEqual(adaptor.appendedFrames.count, 2)
    }

    // MARK: - test_cancelDoesNotHang

    func test_cancelDoesNotHang() {
        let input = MockWriterInput()
        input.isReadyForMoreMediaData = false

        let adaptor = MockPixelBufferAdaptor()
        let queue = DispatchQueue(label: "test.pump")
        let pump = VideoWriterPump(input: input, adaptor: adaptor, queue: queue, onError: { _ in })
        pump.start()

        let exp = expectation(description: "completion called")
        let pb = makeTestPixelBuffer()
        let pts = CMTime(value: 0, timescale: 30)
        pump.enqueue(pb, presentationTime: pts) { exp.fulfill() }

        pump.cancel()

        wait(for: [exp], timeout: 1.0)
        // Should not have appended since input was never ready
        XCTAssertEqual(adaptor.appendedFrames.count, 0)
    }

    // MARK: - test_appendFailureReportsError

    func test_appendFailureReportsError() {
        let input = MockWriterInput()
        let adaptor = MockPixelBufferAdaptor()
        adaptor.shouldFail = true

        let queue = DispatchQueue(label: "test.pump")
        let errorExp = expectation(description: "error reported")
        let pump = VideoWriterPump(input: input, adaptor: adaptor, queue: queue) { _ in
            errorExp.fulfill()
        }
        pump.start()

        let completionExp = expectation(description: "completion called")
        let pb = makeTestPixelBuffer()
        let pts = CMTime(value: 0, timescale: 30)
        pump.enqueue(pb, presentationTime: pts) { completionExp.fulfill() }

        wait(for: [errorExp, completionExp], timeout: 2.0)
    }
}
