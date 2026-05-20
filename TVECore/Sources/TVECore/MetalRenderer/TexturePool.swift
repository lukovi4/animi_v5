import Foundation
import Metal

// MARK: - Texture Pool Configuration

public struct TexturePoolConfiguration: Sendable, Equatable {
    public var softBudgetBytes: Int
    public var hardBudgetBytes: Int
    public var maxAvailableTextures: Int
    public var maxAvailablePerKey: Int
    public var maxIdleGenerations: Int

    public init(
        softBudgetBytes: Int,
        hardBudgetBytes: Int,
        maxAvailableTextures: Int,
        maxAvailablePerKey: Int,
        maxIdleGenerations: Int
    ) {
        self.softBudgetBytes = softBudgetBytes
        self.hardBudgetBytes = hardBudgetBytes
        self.maxAvailableTextures = maxAvailableTextures
        self.maxAvailablePerKey = maxAvailablePerKey
        self.maxIdleGenerations = maxIdleGenerations
    }

    public static let preview = TexturePoolConfiguration(
        softBudgetBytes:      192 * 1024 * 1024,
        hardBudgetBytes:      256 * 1024 * 1024,
        maxAvailableTextures: 512,
        maxAvailablePerKey:   64,
        maxIdleGenerations:   120
    )

    public static let export = TexturePoolConfiguration(
        softBudgetBytes:      64 * 1024 * 1024,
        hardBudgetBytes:      96 * 1024 * 1024,
        maxAvailableTextures: 128,
        maxAvailablePerKey:   16,
        maxIdleGenerations:   30
    )
}

// MARK: - Texture Pool Key

struct TexturePoolKey: Hashable {
    let width: Int
    let height: Int
    let pixelFormat: MTLPixelFormat
    let storageModeRawValue: UInt
    let usageRawValue: UInt

    init(width: Int, height: Int, pixelFormat: MTLPixelFormat,
         storageMode: MTLStorageMode, usage: MTLTextureUsage) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.storageModeRawValue = storageMode.rawValue
        self.usageRawValue = usage.rawValue
    }

    init(size: (width: Int, height: Int), pixelFormat: MTLPixelFormat,
         storageMode: MTLStorageMode, usage: MTLTextureUsage) {
        self.width = size.width
        self.height = size.height
        self.pixelFormat = pixelFormat
        self.storageModeRawValue = storageMode.rawValue
        self.usageRawValue = usage.rawValue
    }
}

// MARK: - Texture Pool Entry

struct TexturePoolEntry {
    let texture: MTLTexture
    let estimatedBytes: Int
    var lastAccessGeneration: UInt64
    #if DEBUG
    var debugOwner: String
    #endif
}

// MARK: - Trim Policy

public enum TrimPolicy {
    case softInteractiveStop
    case memoryWarning
    case editorClose
    case exportFinished
}

// MARK: - Texture Pool

/// Manages reusable Metal textures to avoid per-frame allocations.
/// Textures are pooled by (width, height, pixelFormat, storageMode, usage) key.
/// Bounded pool with per-key caps, LRU eviction, and byte budgets.
public final class TexturePool {
    private let device: MTLDevice
    public let configuration: TexturePoolConfiguration
    private var available: [TexturePoolKey: [TexturePoolEntry]] = [:]
    private var inUse: [ObjectIdentifier: TexturePoolKey] = [:]
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private(set) var totalAvailableBytes: Int = 0

    #if DEBUG
    private var debugTextureOwnerById: [ObjectIdentifier: String] = [:]
    private var debugCreatedByOwnerKey: [DebugOwnerKey: DebugOwnerAllocationStats] = [:]
    private static let debugOwnerThreadDictionaryKey = "TVECore.TexturePool.debugOwner"
    #endif

    public init(device: MTLDevice, configuration: TexturePoolConfiguration = .preview) {
        self.device = device
        self.configuration = configuration
    }

    /// Runs texture allocation code under a debug owner label.
    /// In release builds this is compiled down to the closure call.
    @inline(__always)
    public static func withDebugOwner<T>(_ owner: String, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[debugOwnerThreadDictionaryKey]
        dictionary[debugOwnerThreadDictionaryKey] = owner
        defer {
            if let previous {
                dictionary[debugOwnerThreadDictionaryKey] = previous
            } else {
                dictionary.removeObject(forKey: debugOwnerThreadDictionaryKey)
            }
        }
        #else
        _ = owner
        #endif

        return try body()
    }

    /// Acquires a color texture (BGRA8Unorm) for offscreen rendering.
    public func acquireColorTexture(size: (width: Int, height: Int)) -> MTLTexture? {
        acquire(
            size: size,
            pixelFormat: .bgra8Unorm,
            usage: [.renderTarget, .shaderRead],
            storageMode: .private
        )
    }

    /// Acquires a stencil texture (depth32Float_stencil8) for mask rendering.
    func acquireStencilTexture(size: (width: Int, height: Int)) -> MTLTexture? {
        acquire(
            size: size,
            pixelFormat: .depth32Float_stencil8,
            usage: [.renderTarget],
            storageMode: .private
        )
    }

    /// Acquires a mask texture (r8Unorm) for alpha mask storage (CPU raster path).
    func acquireMaskTexture(size: (width: Int, height: Int)) -> MTLTexture? {
        acquire(
            size: size,
            pixelFormat: .r8Unorm,
            usage: [.shaderRead],
            storageMode: .shared
        )
    }

    /// Acquires an R8 texture for GPU mask accumulator or coverage rendering.
    func acquireR8Texture(size: (width: Int, height: Int)) -> MTLTexture? {
        acquire(
            size: size,
            pixelFormat: .r8Unorm,
            usage: [.renderTarget, .shaderRead, .shaderWrite],
            storageMode: .private
        )
    }

    /// Releases a texture back to the pool for reuse.
    public func release(_ texture: MTLTexture) {
        let identifier = ObjectIdentifier(texture)
        var evicted: [TexturePoolEntry] = []

        lock.lock()

        guard let key = inUse.removeValue(forKey: identifier) else {
            lock.unlock()
            return
        }

        #if DEBUG
        let debugOwner = debugTextureOwnerById.removeValue(forKey: identifier) ?? "unattributed"
        #endif

        let estimatedBytes = key.width * key.height * Self.bytesPerPixel(key.pixelFormat)

        // Oversized texture: don't cache
        if estimatedBytes > configuration.softBudgetBytes / 4 {
            lock.unlock()
            // texture deallocs outside lock
            return
        }

        // Cache the entry
        #if DEBUG
        let entry = TexturePoolEntry(
            texture: texture, estimatedBytes: estimatedBytes,
            lastAccessGeneration: generation, debugOwner: debugOwner)
        #else
        let entry = TexturePoolEntry(
            texture: texture, estimatedBytes: estimatedBytes,
            lastAccessGeneration: generation)
        #endif
        available[key, default: []].append(entry)
        totalAvailableBytes += estimatedBytes

        // Per-key cap
        if let count = available[key]?.count, count > configuration.maxAvailablePerKey {
            let excess = count - configuration.maxAvailablePerKey
            let removed = Array(available[key]![..<excess])
            available[key]!.removeFirst(excess)
            for r in removed {
                totalAvailableBytes -= r.estimatedBytes
            }
            evicted.append(contentsOf: removed)
        }

        // Global texture count cap
        evicted.append(contentsOf: evictWhile { totalAvailableCount() > configuration.maxAvailableTextures })

        // Idle generations eviction
        evicted.append(contentsOf: evictIdle())

        // Soft budget
        evicted.append(contentsOf: evictWhile { totalAvailableBytes > configuration.softBudgetBytes })

        // Hard budget safety
        evicted.append(contentsOf: evictWhile { totalAvailableBytes > configuration.hardBudgetBytes })

        lock.unlock()
        // evicted entries dealloc outside lock
        _ = evicted
    }

    /// Lifecycle-safe trim. Does not affect in-use textures.
    public func trim(policy: TrimPolicy) {
        var evicted: [TexturePoolEntry] = []
        lock.lock()
        switch policy {
        case .softInteractiveStop:
            evicted = evictWhile { totalAvailableBytes > configuration.softBudgetBytes }
        case .memoryWarning:
            evicted = evictWhile { totalAvailableBytes > configuration.softBudgetBytes / 2 }
        case .editorClose, .exportFinished:
            evicted = collectAllAvailable()
        }
        lock.unlock()
        _ = evicted
    }

    /// Quiescent-renderer reset. Do not call while command buffers
    /// can still release textures back to this pool.
    /// Lifecycle-safe trim is provided by `trim(policy:)`.
    func clear() {
        var evicted: [TexturePoolEntry] = []
        lock.lock()
        evicted = collectAllAvailable()
        inUse.removeAll()
        generation = 0
        #if DEBUG
        debugTextureOwnerById.removeAll()
        debugCreatedByOwnerKey.removeAll()
        #endif
        lock.unlock()
        _ = evicted
    }

    // MARK: - Private

    private func acquire(
        size: (width: Int, height: Int),
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage,
        storageMode: MTLStorageMode
    ) -> MTLTexture? {
        let key = TexturePoolKey(size: size, pixelFormat: pixelFormat,
                                 storageMode: storageMode, usage: usage)
        #if DEBUG
        let debugOwner = Self.currentDebugOwner()
        #endif

        lock.lock()
        generation += 1

        // Try to reuse existing texture
        if var textures = available[key], !textures.isEmpty {
            let entry = textures.removeLast()
            if textures.isEmpty {
                available.removeValue(forKey: key)
            } else {
                available[key] = textures
            }
            totalAvailableBytes -= entry.estimatedBytes
            let identifier = ObjectIdentifier(entry.texture)
            inUse[identifier] = key
            #if DEBUG
            debugTextureOwnerById[identifier] = debugOwner
            #endif
            lock.unlock()
            return entry.texture
        }

        lock.unlock()

        // Create new texture (outside lock — device.makeTexture may be slow)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = storageMode

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let identifier = ObjectIdentifier(texture)
        lock.lock()
        inUse[identifier] = key
        #if DEBUG
        debugTextureOwnerById[identifier] = debugOwner
        recordCreatedTexture(owner: debugOwner, key: key)
        #endif
        lock.unlock()
        return texture
    }

    // MARK: - Eviction helpers (must be called under lock)

    private func totalAvailableCount() -> Int {
        available.values.reduce(0) { $0 + $1.count }
    }

    /// Evict global LRU entries while `condition` is true. Returns evicted entries.
    private func evictWhile(_ condition: () -> Bool) -> [TexturePoolEntry] {
        var evicted: [TexturePoolEntry] = []
        while condition() {
            guard let entry = removeGlobalLRU() else { break }
            evicted.append(entry)
        }
        return evicted
    }

    /// Remove the entry with the smallest lastAccessGeneration across all keys.
    private func removeGlobalLRU() -> TexturePoolEntry? {
        var oldestKey: TexturePoolKey?
        var oldestGen: UInt64 = .max
        var oldestIndex: Int = 0

        for (key, entries) in available {
            for (index, entry) in entries.enumerated() {
                if entry.lastAccessGeneration < oldestGen {
                    oldestGen = entry.lastAccessGeneration
                    oldestKey = key
                    oldestIndex = index
                }
            }
        }

        guard let key = oldestKey else { return nil }
        let entry = available[key]!.remove(at: oldestIndex)
        if available[key]!.isEmpty {
            available.removeValue(forKey: key)
        }
        totalAvailableBytes -= entry.estimatedBytes
        return entry
    }

    /// Evict entries idle for more than maxIdleGenerations.
    private func evictIdle() -> [TexturePoolEntry] {
        var evicted: [TexturePoolEntry] = []
        let threshold = configuration.maxIdleGenerations
        for key in Array(available.keys) {
            guard let entries = available[key] else { continue }
            var kept: [TexturePoolEntry] = []
            for entry in entries {
                if generation >= entry.lastAccessGeneration,
                   (generation - entry.lastAccessGeneration) > UInt64(threshold) {
                    totalAvailableBytes -= entry.estimatedBytes
                    evicted.append(entry)
                } else {
                    kept.append(entry)
                }
            }
            if kept.isEmpty {
                available.removeValue(forKey: key)
            } else if kept.count != entries.count {
                available[key] = kept
            }
        }
        return evicted
    }

    /// Collect all available entries and reset tracking. Must be called under lock.
    private func collectAllAvailable() -> [TexturePoolEntry] {
        var evicted: [TexturePoolEntry] = []
        for (_, entries) in available {
            evicted.append(contentsOf: entries)
        }
        available.removeAll()
        totalAvailableBytes = 0
        return evicted
    }

    static func bytesPerPixel(_ format: MTLPixelFormat) -> Int {
        switch format {
        case .bgra8Unorm, .rgba8Unorm: return 4
        case .r8Unorm: return 1
        case .depth32Float_stencil8: return 5
        default: return 4
        }
    }

    #if DEBUG
    private struct DebugOwnerKey: Hashable {
        let owner: String
        let key: TexturePoolKey
    }

    private struct DebugOwnerAllocationStats {
        var createdCount: Int
        var estimatedBytes: Int
    }

    private static func currentDebugOwner() -> String {
        Thread.current.threadDictionary[debugOwnerThreadDictionaryKey] as? String ?? "unattributed"
    }

    private func recordCreatedTexture(owner: String, key: TexturePoolKey) {
        let ownerKey = DebugOwnerKey(owner: owner, key: key)
        let estimatedBytes = key.width * key.height * Self.bytesPerPixel(key.pixelFormat)
        var stats = debugCreatedByOwnerKey[ownerKey]
            ?? DebugOwnerAllocationStats(createdCount: 0, estimatedBytes: 0)
        stats.createdCount += 1
        stats.estimatedBytes += estimatedBytes
        debugCreatedByOwnerKey[ownerKey] = stats
    }
    #endif
}

#if DEBUG
extension TexturePool {

    public struct TexturePoolKeySnapshot {
        public let width: Int
        public let height: Int
        public let pixelFormat: MTLPixelFormat
        public let availableCount: Int
        public let inUseCount: Int
        public let estimatedBytes: Int
    }

    public struct TexturePoolSnapshot {
        public let availableCount: Int
        public let inUseCount: Int
        public let availableEstimatedBytes: Int
        public let inUseEstimatedBytes: Int
        public let totalEstimatedBytes: Int
        public let keyBreakdown: [TexturePoolKeySnapshot]
        public let ownerTotals: [TexturePoolOwnerTotalSnapshot]
        public let ownerBreakdown: [TexturePoolOwnerSnapshot]
    }

    public struct TexturePoolOwnerTotalSnapshot {
        public let owner: String
        public let createdCount: Int
        public let estimatedBytes: Int
    }

    public struct TexturePoolOwnerSnapshot {
        public let owner: String
        public let width: Int
        public let height: Int
        public let pixelFormat: MTLPixelFormat
        public let createdCount: Int
        public let estimatedBytes: Int
    }

    public func debugSnapshot() -> TexturePoolSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var inUsePerKey: [TexturePoolKey: Int] = [:]
        for (_, key) in inUse {
            inUsePerKey[key, default: 0] += 1
        }

        var allKeys = Set(available.keys)
        for key in inUsePerKey.keys { allKeys.insert(key) }

        var totalAvail = 0
        var totalAvailBytes = 0
        var totalInUseCount = 0
        var totalInUseBytes = 0
        var breakdown: [TexturePoolKeySnapshot] = []
        var ownerTotalsByOwner: [String: (createdCount: Int, estimatedBytes: Int)] = [:]
        var ownerBreakdown: [TexturePoolOwnerSnapshot] = []

        for key in allKeys {
            let bpp = Self.bytesPerPixel(key.pixelFormat)
            let perTexture = key.width * key.height * bpp

            let availCount = available[key]?.count ?? 0
            let inUseCount = inUsePerKey[key] ?? 0

            totalAvail += availCount
            totalAvailBytes += availCount * perTexture
            totalInUseCount += inUseCount
            totalInUseBytes += inUseCount * perTexture

            let totalForKey = (availCount + inUseCount) * perTexture
            breakdown.append(TexturePoolKeySnapshot(
                width: key.width, height: key.height,
                pixelFormat: key.pixelFormat,
                availableCount: availCount,
                inUseCount: inUseCount,
                estimatedBytes: totalForKey
            ))
        }

        for (ownerKey, stats) in debugCreatedByOwnerKey {
            let current = ownerTotalsByOwner[ownerKey.owner] ?? (createdCount: 0, estimatedBytes: 0)
            ownerTotalsByOwner[ownerKey.owner] = (
                createdCount: current.createdCount + stats.createdCount,
                estimatedBytes: current.estimatedBytes + stats.estimatedBytes
            )
            ownerBreakdown.append(TexturePoolOwnerSnapshot(
                owner: ownerKey.owner,
                width: ownerKey.key.width,
                height: ownerKey.key.height,
                pixelFormat: ownerKey.key.pixelFormat,
                createdCount: stats.createdCount,
                estimatedBytes: stats.estimatedBytes
            ))
        }

        let ownerTotals = ownerTotalsByOwner
            .map { owner, stats in
                TexturePoolOwnerTotalSnapshot(
                    owner: owner,
                    createdCount: stats.createdCount,
                    estimatedBytes: stats.estimatedBytes
                )
            }
            .sorted {
                if $0.estimatedBytes == $1.estimatedBytes {
                    return $0.owner < $1.owner
                }
                return $0.estimatedBytes > $1.estimatedBytes
            }

        ownerBreakdown.sort {
            if $0.estimatedBytes == $1.estimatedBytes {
                if $0.owner == $1.owner {
                    return $0.createdCount > $1.createdCount
                }
                return $0.owner < $1.owner
            }
            return $0.estimatedBytes > $1.estimatedBytes
        }

        return TexturePoolSnapshot(
            availableCount: totalAvail, inUseCount: totalInUseCount,
            availableEstimatedBytes: totalAvailBytes,
            inUseEstimatedBytes: totalInUseBytes,
            totalEstimatedBytes: totalAvailBytes + totalInUseBytes,
            keyBreakdown: breakdown,
            ownerTotals: ownerTotals,
            ownerBreakdown: ownerBreakdown
        )
    }
}
#endif
