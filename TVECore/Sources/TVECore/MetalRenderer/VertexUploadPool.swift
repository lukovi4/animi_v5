import Metal

// MARK: - Vertex Upload Pool

/// Ring buffer pool for uploading vertex data to GPU without per-op allocations.
///
/// Uses multiple buffers (ring) to avoid GPU/CPU data hazards when GPU is still
/// reading data from previous frames (typically 1-3 frames behind).
///
/// Usage:
/// 1. Call `beginFrame()` at the start of each frame (rotates to next buffer in ring)
/// 2. Call `uploadFloats(_:)` to upload vertex data
/// 3. Use returned `Slice` for `setVertexBuffer(slice.buffer, offset: slice.offset, ...)`
///
/// The pool manages N shared MTLBuffers internally (default 3 for triple buffering)
/// and handles growth when needed (rare, only on first few frames or very large paths).
final class VertexUploadPool {
    /// A slice of the upload buffer containing uploaded data.
    struct Slice {
        let buffer: MTLBuffer
        let offset: Int
        let length: Int
    }

    /// Default initial capacity per buffer (256 KB)
    static let defaultCapacity = 256 * 1024

    /// Default number of buffers in ring (triple buffering)
    static let defaultBuffersInFlight = 3

    /// Alignment for vertex data (16 bytes for SIMD compatibility)
    private static let alignment = 16

    private let device: MTLDevice
    private let buffersInFlight: Int
    private let initialCapacity: Int

    /// Ring of buffers, one per in-flight frame
    private var buffers: [MTLBuffer?]
    /// Capacity of each buffer in ring (can grow independently)
    private var capacities: [Int]
    /// Current buffer index in ring (starts at buffersInFlight-1 so first beginFrame selects 0)
    private var bufferIndex: Int
    /// Current write offset in active buffer
    private var currentOffset: Int = 0

    #if DEBUG
    /// Number of times a new MTLBuffer was created (for testing)
    private(set) var debugCreatedBuffersCount: Int = 0
    /// Current buffer index (for testing)
    var debugCurrentBufferIndex: Int { bufferIndex }
    /// Whether beginFrame was called this frame (for contract validation)
    private var frameStarted: Bool = false
    #endif

    /// Creates a vertex upload pool with ring buffer.
    /// - Parameters:
    ///   - device: Metal device for buffer creation
    ///   - buffersInFlight: Number of buffers in ring (default 3 for triple buffering)
    ///   - initialCapacityBytes: Initial buffer capacity in bytes per buffer
    init(
        device: MTLDevice,
        buffersInFlight: Int = defaultBuffersInFlight,
        initialCapacityBytes: Int = defaultCapacity
    ) {
        self.device = device
        self.buffersInFlight = max(1, buffersInFlight)
        self.initialCapacity = initialCapacityBytes
        self.buffers = [MTLBuffer?](repeating: nil, count: self.buffersInFlight)
        self.capacities = [Int](repeating: initialCapacityBytes, count: self.buffersInFlight)
        // Start at buffersInFlight-1 so first beginFrame() selects buffer 0
        self.bufferIndex = self.buffersInFlight - 1
    }

    /// Begins a new frame by rotating to the next buffer in ring.
    /// Call this at the start of each frame before any uploads.
    ///
    /// This ensures we don't overwrite data that GPU may still be reading
    /// from previous frames.
    ///
    /// - Important: Must be called before any `uploadFloats()` calls in a frame.
    func beginFrame() {
        bufferIndex = (bufferIndex + 1) % buffersInFlight
        currentOffset = 0
        #if DEBUG
        frameStarted = true
        #endif
    }

    /// Uploads float array to the pool and returns a slice.
    ///
    /// - Important: `beginFrame()` must be called before this method in each frame.
    /// - Parameter floats: Float array to upload
    /// - Returns: Slice containing buffer, offset, and length; or nil if allocation fails
    func uploadFloats(_ floats: [Float]) -> Slice? {
        #if DEBUG
        precondition(frameStarted, "uploadFloats() called before beginFrame(). Must call beginFrame() at start of each frame.")
        #endif

        let byteCount = floats.count * MemoryLayout<Float>.stride
        guard byteCount > 0 else { return nil }

        // Align offset
        let alignedOffset = Self.alignUp(currentOffset, Self.alignment)
        let requiredCapacity = alignedOffset + byteCount

        // Get current buffer and its capacity
        var currentBuffer = buffers[bufferIndex]
        var currentCapacity = capacities[bufferIndex]

        // Ensure buffer exists and has enough capacity
        if currentBuffer == nil {
            // First allocation for this buffer slot - use initial or required capacity
            let newCapacity = max(initialCapacity, requiredCapacity)
            guard let newBuffer = device.makeBuffer(length: newCapacity, options: .storageModeShared) else {
                return nil
            }
            currentBuffer = newBuffer
            currentCapacity = newCapacity
            buffers[bufferIndex] = newBuffer
            capacities[bufferIndex] = newCapacity
            #if DEBUG
            debugCreatedBuffersCount += 1
            #endif
        } else if requiredCapacity > currentCapacity {
            // Need to grow this buffer - use 2x or required capacity
            let newCapacity = max(currentCapacity * 2, requiredCapacity)
            guard let newBuffer = device.makeBuffer(length: newCapacity, options: .storageModeShared) else {
                return nil
            }
            currentBuffer = newBuffer
            currentCapacity = newCapacity
            buffers[bufferIndex] = newBuffer
            capacities[bufferIndex] = newCapacity
            // Reset offset since we have a fresh buffer
            currentOffset = 0
            #if DEBUG
            debugCreatedBuffersCount += 1
            #endif
        }

        guard let buf = currentBuffer else { return nil }

        // Recalculate aligned offset (may have changed if buffer was reallocated)
        let alignedOffsetFinal = Self.alignUp(currentOffset, Self.alignment)

        // Copy data
        let dest = buf.contents().advanced(by: alignedOffsetFinal)
        _ = floats.withUnsafeBytes { src in
            memcpy(dest, src.baseAddress!, byteCount)
        }

        // Advance offset
        currentOffset = alignedOffsetFinal + byteCount

        return Slice(buffer: buf, offset: alignedOffsetFinal, length: byteCount)
    }

    /// Aligns value up to the given alignment.
    private static func alignUp(_ value: Int, _ alignment: Int) -> Int {
        (value + alignment - 1) & ~(alignment - 1)
    }
}

// MARK: - Path Index Buffer Cache

/// Cache for index buffers keyed by PathID.
///
/// Index buffers are stable per PathResource (indices don't change across frames),
/// so we cache them to avoid per-op allocations.
final class PathIndexBufferCache {
    private var cache: [PathID: MTLBuffer] = [:]
    private let device: MTLDevice

    #if DEBUG
    /// Number of times a new index buffer was created (for testing)
    private(set) var debugCreatedBuffersCount: Int = 0
    #endif

    init(device: MTLDevice) {
        self.device = device
    }

    /// Gets or creates an index buffer for the given path.
    ///
    /// - Parameters:
    ///   - pathId: Path identifier
    ///   - indices: Index data (only used if buffer doesn't exist)
    /// - Returns: Cached or newly created MTLBuffer, or nil if creation fails
    func getOrCreate(for pathId: PathID, indices: [UInt16]) -> MTLBuffer? {
        // Check cache
        if let existing = cache[pathId] {
            return existing
        }

        // Create new buffer
        let byteCount = indices.count * MemoryLayout<UInt16>.stride
        guard byteCount > 0,
              let newBuffer = device.makeBuffer(bytes: indices, length: byteCount, options: .storageModeShared) else {
            return nil
        }

        cache[pathId] = newBuffer
        #if DEBUG
        debugCreatedBuffersCount += 1
        #endif
        return newBuffer
    }

    /// Clears all cached buffers.
    func clear() {
        cache.removeAll()
    }

    /// Number of cached buffers.
    var count: Int { cache.count }
}
