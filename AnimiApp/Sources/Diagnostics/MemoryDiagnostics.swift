#if DEBUG
import Foundation
import os.log
import Metal
import TVECore

/// Debug-only memory diagnostics. Toggle: -DebugMemoryDiagnostics YES
enum MemoryDiagnostics {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "DebugMemoryDiagnostics")
    }

    static var isVerbosePoolEnabled: Bool {
        UserDefaults.standard.bool(forKey: "DebugMemoryDiagnosticsVerbosePool")
    }

    static var isVerboseRuntimeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "DebugMemoryDiagnosticsVerboseRuntime")
    }

    // MARK: - Thread-safe counters

    private static let lock = NSLock()
    private static var _counters: [String: Int] = [:]

    static var counters: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return _counters
    }

    static func increment(_ key: String) {
        guard isEnabled else { return }
        lock.lock()
        _counters[key, default: 0] += 1
        lock.unlock()
    }

    static func decrement(_ key: String) {
        guard isEnabled else { return }
        lock.lock()
        _counters[key, default: 0] -= 1
        lock.unlock()
    }

    // MARK: - Lifecycle event

    static func event(_ tag: String, _ detail: String = "") {
        guard isEnabled else { return }
        let suffix = detail.isEmpty ? "" : " | \(detail)"
        print("[MEM-EVENT] \(tag)\(suffix)")
    }

    // MARK: - Memory checkpoint

    static func checkpoint(_ label: String, metal device: MTLDevice? = nil) {
        guard isEnabled else { return }
        let mem = ProcessMemory.sample()
        let footprint = PerfFormat.bytesToMB(mem.physFootprintBytes)
        let resident = PerfFormat.bytesToMB(mem.residentBytes)
        let available = Int(os_proc_available_memory()) / (1024 * 1024)
        let metalMB = device.map { PerfFormat.bytesToMB(UInt64($0.currentAllocatedSize)) }
        let metalStr = metalMB.map { String(format: "%.0f", $0) } ?? "n/a"

        let snap = counters
        let counterStr = snap.sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " | ")

        print("[MEM-DIAG] \(label) | footprint: \(String(format: "%.0f", footprint))MB | resident: \(String(format: "%.0f", resident))MB | available: \(available)MB | metal: \(metalStr)MB | \(counterStr)")
    }

    // MARK: - Resource Context Checkpoint

    struct ResourceContext {
        var texturePoolSnapshot: TexturePool.TexturePoolSnapshot? = nil
        var sceneTypeCacheSnapshot: SceneTypeResourcesCache.DebugSnapshot? = nil
        var overlayCacheSnapshot: OverlayRenderResourceCache.DebugSnapshot? = nil
        var runtimeCount: Int? = nil
        var videoProviderCount: Int? = nil
    }

    static func checkpoint(_ label: String, metal device: MTLDevice? = nil, resources: ResourceContext) {
        guard isEnabled else { return }
        checkpoint(label, metal: device)

        if let tp = resources.texturePoolSnapshot {
            let availMB = PerfFormat.bytesToMB(UInt64(tp.availableEstimatedBytes))
            let inUseMB = PerfFormat.bytesToMB(UInt64(tp.inUseEstimatedBytes))
            let totalMB = PerfFormat.bytesToMB(UInt64(tp.totalEstimatedBytes))
            print("[MEM-DIAG]   pool | avail: \(tp.availableCount) (\(String(format: "%.1f", availMB))MB) | inUse: \(tp.inUseCount) (~\(String(format: "%.1f", inUseMB))MB) | total: ~\(String(format: "%.1f", totalMB))MB")
            for owner in tp.ownerTotals.prefix(8) where owner.createdCount > 0 {
                let ownerMB = PerfFormat.bytesToMB(UInt64(owner.estimatedBytes))
                print("[MEM-DIAG]   pool.owner | owner=\(owner.owner) created=\(owner.createdCount) MB=\(String(format: "%.1f", ownerMB))")
            }
            if isVerbosePoolEnabled {
                for k in tp.keyBreakdown where (k.availableCount + k.inUseCount) > 0 {
                    let kmb = PerfFormat.bytesToMB(UInt64(k.estimatedBytes))
                    print("[MEM-DIAG]   pool.key | \(k.width)x\(k.height) fmt=\(k.pixelFormat.rawValue) avail=\(k.availableCount) inUse=\(k.inUseCount) MB=\(String(format: "%.1f", kmb))")
                }
                for ownerKey in tp.ownerBreakdown where ownerKey.createdCount > 0 {
                    let ownerKeyMB = PerfFormat.bytesToMB(UInt64(ownerKey.estimatedBytes))
                    print("[MEM-DIAG]   pool.owner.key | owner=\(ownerKey.owner) \(ownerKey.width)x\(ownerKey.height) fmt=\(ownerKey.pixelFormat.rawValue) created=\(ownerKey.createdCount) MB=\(String(format: "%.1f", ownerKeyMB))")
                }
            }
        }
        if let sc = resources.sceneTypeCacheSnapshot {
            let texMB = PerfFormat.bytesToMB(UInt64(sc.estimatedTextureBytes))
            print("[MEM-DIAG]   sceneTypeCache | cached: \(sc.cachedCount) [\(sc.cachedIds.joined(separator: ","))] loading: \(sc.loadingCount) | textures: \(sc.totalTextureCount) ~\(String(format: "%.1f", texMB))MB")
        }
        if let oc = resources.overlayCacheSnapshot {
            let mb = PerfFormat.bytesToMB(UInt64(oc.estimatedBytes))
            print("[MEM-DIAG]   overlayCache | entries: \(oc.entryCount) MB: \(String(format: "%.1f", mb))")
        }
        if let rc = resources.runtimeCount {
            print("[MEM-DIAG]   runtimes: \(rc)")
        }
        if let vpc = resources.videoProviderCount {
            print("[MEM-DIAG]   videoProviders: \(vpc)")
        }
    }

    // MARK: - os_signpost for Instruments

    static let signpostLog = OSLog(subsystem: "com.animi.memory-diagnostics", category: .pointsOfInterest)

    static func signpostEvent(_ name: StaticString) {
        guard isEnabled else { return }
        os_signpost(.event, log: signpostLog, name: name)
    }
}
#endif
