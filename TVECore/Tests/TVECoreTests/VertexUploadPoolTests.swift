import XCTest
import Metal
@testable import TVECore

// MARK: - Vertex Upload Pool Tests (PR-C3)

final class VertexUploadPoolTests: XCTestCase {
    var device: MTLDevice!

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        try XCTSkipIf(device == nil, "Metal not available")
    }

    override func tearDown() {
        device = nil
    }

    // MARK: - VertexUploadPool Tests

    /// Test that pool returns valid slices with correct length
    func testUploadFloatsReturnsValidSlice() throws {
        let pool = VertexUploadPool(device: device)
        let floats: [Float] = [1.0, 2.0, 3.0, 4.0]

        pool.beginFrame() // Required before uploadFloats
        let slice = pool.uploadFloats(floats)

        XCTAssertNotNil(slice, "Should return valid slice")
        XCTAssertEqual(slice?.length, floats.count * MemoryLayout<Float>.stride,
                       "Slice length should match float array byte size")
    }

    /// Test that pool reuses buffer after beginFrame within same buffer slot
    func testPoolReusesBufferAfterFullRingRotation() throws {
        let pool = VertexUploadPool(device: device, buffersInFlight: 3, initialCapacityBytes: 1024)
        let floats: [Float] = [1.0, 2.0, 3.0, 4.0]

        // First frame - buffer 0 allocated
        pool.beginFrame()
        _ = pool.uploadFloats(floats)

        // Second frame - buffer 1 allocated
        pool.beginFrame()
        _ = pool.uploadFloats(floats)

        // Third frame - buffer 2 allocated
        pool.beginFrame()
        _ = pool.uploadFloats(floats)

        #if DEBUG
        XCTAssertEqual(pool.debugCreatedBuffersCount, 3, "Should create 3 buffers for ring")
        #endif

        // Fourth frame - back to buffer 0, should reuse
        pool.beginFrame()
        _ = pool.uploadFloats(floats)

        #if DEBUG
        XCTAssertEqual(pool.debugCreatedBuffersCount, 3,
                       "Should reuse buffer 0 after full ring rotation, no new allocations")
        #endif
    }

    /// Test that beginFrame rotates buffer index correctly
    func testBeginFrameRotatesBufferIndex() throws {
        let pool = VertexUploadPool(device: device, buffersInFlight: 3, initialCapacityBytes: 1024)

        #if DEBUG
        // Initial state: bufferIndex = buffersInFlight - 1 = 2
        XCTAssertEqual(pool.debugCurrentBufferIndex, 2, "Should start at buffer 2 (buffersInFlight - 1)")

        pool.beginFrame()
        XCTAssertEqual(pool.debugCurrentBufferIndex, 0, "First beginFrame should select buffer 0")

        pool.beginFrame()
        XCTAssertEqual(pool.debugCurrentBufferIndex, 1, "Should rotate to buffer 1")

        pool.beginFrame()
        XCTAssertEqual(pool.debugCurrentBufferIndex, 2, "Should rotate to buffer 2")

        pool.beginFrame()
        XCTAssertEqual(pool.debugCurrentBufferIndex, 0, "Should wrap around to buffer 0")
        #endif
    }

    /// Test that different frames use different buffers (in-flight safety)
    func testDifferentFramesUseDifferentBuffers() throws {
        let pool = VertexUploadPool(device: device, buffersInFlight: 3, initialCapacityBytes: 1024)
        let floats: [Float] = [1.0, 2.0, 3.0, 4.0]

        // Frame 0
        pool.beginFrame()
        let slice0 = try XCTUnwrap(pool.uploadFloats(floats))

        // Frame 1
        pool.beginFrame()
        let slice1 = try XCTUnwrap(pool.uploadFloats(floats))

        // Frame 2
        pool.beginFrame()
        let slice2 = try XCTUnwrap(pool.uploadFloats(floats))

        // All three slices should use different buffers
        XCTAssertFalse(slice0.buffer === slice1.buffer, "Frame 0 and 1 should use different buffers")
        XCTAssertFalse(slice1.buffer === slice2.buffer, "Frame 1 and 2 should use different buffers")
        XCTAssertFalse(slice0.buffer === slice2.buffer, "Frame 0 and 2 should use different buffers")
    }

    /// Test that multiple uploads in same frame use same buffer with different offsets
    func testMultipleUploadsUseSameBuffer() throws {
        let pool = VertexUploadPool(device: device, buffersInFlight: 3, initialCapacityBytes: 4096)
        let floats1: [Float] = [1.0, 2.0, 3.0, 4.0]
        let floats2: [Float] = [5.0, 6.0, 7.0, 8.0]

        pool.beginFrame()
        let slice1 = try XCTUnwrap(pool.uploadFloats(floats1))
        let slice2 = try XCTUnwrap(pool.uploadFloats(floats2))

        // Same buffer
        XCTAssertTrue(slice1.buffer === slice2.buffer, "Should use same buffer within frame")
        // Different offsets
        XCTAssertNotEqual(slice1.offset, slice2.offset, "Should have different offsets")
    }

    /// Test that pool grows when capacity exceeded
    func testPoolGrowsWhenCapacityExceeded() throws {
        let pool = VertexUploadPool(device: device, buffersInFlight: 3, initialCapacityBytes: 64)
        // 100 floats = 400 bytes > 64 bytes initial capacity
        let largeFloats = [Float](repeating: 1.0, count: 100)

        pool.beginFrame()
        let slice = pool.uploadFloats(largeFloats)

        XCTAssertNotNil(slice, "Should succeed even when exceeding initial capacity")
        XCTAssertEqual(slice?.length, largeFloats.count * MemoryLayout<Float>.stride)
    }

    /// Test that first allocation uses initial capacity (not x2)
    func testFirstAllocationUsesInitialCapacity() throws {
        let initialCapacity = 1024
        let pool = VertexUploadPool(device: device, buffersInFlight: 1, initialCapacityBytes: initialCapacity)
        let smallFloats: [Float] = [1.0, 2.0, 3.0, 4.0] // 16 bytes, well under 1024

        pool.beginFrame()
        let slice = try XCTUnwrap(pool.uploadFloats(smallFloats))

        // Buffer should exist and have at least initial capacity
        // (we can't directly check capacity, but we can verify allocation happened once)
        #if DEBUG
        XCTAssertEqual(pool.debugCreatedBuffersCount, 1, "Should create exactly one buffer")
        #endif
        XCTAssertNotNil(slice.buffer)
    }

    /// Test that offset is aligned
    func testOffsetIsAligned() throws {
        let pool = VertexUploadPool(device: device, buffersInFlight: 3, initialCapacityBytes: 4096)
        // Upload odd-sized data to potentially misalign
        let floats1: [Float] = [1.0, 2.0, 3.0] // 12 bytes
        let floats2: [Float] = [4.0, 5.0]

        pool.beginFrame()
        _ = pool.uploadFloats(floats1)
        let slice2 = try XCTUnwrap(pool.uploadFloats(floats2))

        // Offset should be aligned to 16 bytes
        XCTAssertEqual(slice2.offset % 16, 0, "Offset should be 16-byte aligned")
    }

    /// Test that first beginFrame selects buffer 0
    func testFirstBeginFrameSelectsBuffer0() throws {
        let pool = VertexUploadPool(device: device, buffersInFlight: 3, initialCapacityBytes: 1024)

        #if DEBUG
        // After first beginFrame, should be at buffer 0
        pool.beginFrame()
        XCTAssertEqual(pool.debugCurrentBufferIndex, 0, "First beginFrame should select buffer 0")
        #endif
    }

    // MARK: - PathIndexBufferCache Tests

    /// Test that cache returns same buffer for same pathId
    func testIndexBufferCacheReturnsSameBuffer() throws {
        let cache = PathIndexBufferCache(device: device)
        let pathId = PathID(42)
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]

        let buffer1 = cache.getOrCreate(for: pathId, indices: indices)
        let buffer2 = cache.getOrCreate(for: pathId, indices: indices)

        XCTAssertNotNil(buffer1)
        XCTAssertTrue(buffer1 === buffer2, "Should return same buffer for same pathId")
    }

    /// Test that cache creates buffer only once per pathId
    func testIndexBufferCacheCreatesOnce() throws {
        let cache = PathIndexBufferCache(device: device)
        let pathId = PathID(1)
        let indices: [UInt16] = [0, 1, 2]

        _ = cache.getOrCreate(for: pathId, indices: indices)
        _ = cache.getOrCreate(for: pathId, indices: indices)
        _ = cache.getOrCreate(for: pathId, indices: indices)

        #if DEBUG
        XCTAssertEqual(cache.debugCreatedBuffersCount, 1,
                       "Should create buffer only once for same pathId")
        #endif
    }

    /// Test that cache creates different buffers for different pathIds
    func testIndexBufferCacheDifferentPaths() throws {
        let cache = PathIndexBufferCache(device: device)
        let pathId1 = PathID(1)
        let pathId2 = PathID(2)
        let indices: [UInt16] = [0, 1, 2]

        let buffer1 = cache.getOrCreate(for: pathId1, indices: indices)
        let buffer2 = cache.getOrCreate(for: pathId2, indices: indices)

        XCTAssertNotNil(buffer1)
        XCTAssertNotNil(buffer2)
        XCTAssertFalse(buffer1 === buffer2, "Different pathIds should have different buffers")
        XCTAssertEqual(cache.count, 2)
    }

    /// Test that clear removes all cached buffers
    func testIndexBufferCacheClear() throws {
        let cache = PathIndexBufferCache(device: device)
        _ = cache.getOrCreate(for: PathID(1), indices: [0, 1, 2])
        _ = cache.getOrCreate(for: PathID(2), indices: [0, 1, 2])

        XCTAssertEqual(cache.count, 2)

        cache.clear()

        XCTAssertEqual(cache.count, 0, "Clear should remove all cached buffers")
    }

    // MARK: - Sampling Performance Tests (I5)

    /// Test that sampling doesn't grow capacity after warmup
    func testSamplingNoSteadyStateAllocation() throws {
        // Create animated path resource
        let positions1: [Float] = [0, 0, 10, 0, 10, 10, 0, 10]
        let positions2: [Float] = [0, 0, 20, 0, 20, 20, 0, 20]
        let resource = PathResource(
            pathId: PathID(0),
            keyframePositions: [positions1, positions2],
            keyframeTimes: [0, 30],
            indices: [0, 1, 2, 0, 2, 3],
            vertexCount: 4
        )

        var scratch: [Float] = []

        // Warmup - first call may allocate
        resource.sampleTriangulatedPositions(at: 15, into: &scratch)
        let capacityAfterWarmup = scratch.capacity

        // Multiple sampling calls should not increase capacity
        for frame in stride(from: 0.0, through: 30.0, by: 1.0) {
            resource.sampleTriangulatedPositions(at: frame, into: &scratch)
        }

        XCTAssertEqual(scratch.capacity, capacityAfterWarmup,
                       "Capacity should not grow after warmup")
    }

    /// Test that reserveCapacity is called (capacity >= vertexCount * 2)
    func testSamplingReservesCapacity() throws {
        let vertexCount = 100
        let positions = [Float](repeating: 0, count: vertexCount * 2)
        let resource = PathResource(
            pathId: PathID(0),
            keyframePositions: [positions],
            keyframeTimes: [0],
            indices: [],
            vertexCount: vertexCount
        )

        var scratch: [Float] = []
        resource.sampleTriangulatedPositions(at: 0, into: &scratch)

        XCTAssertGreaterThanOrEqual(scratch.capacity, vertexCount * 2,
                                    "Capacity should be at least vertexCount * 2")
    }
}
