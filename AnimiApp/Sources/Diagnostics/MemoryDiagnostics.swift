#if DEBUG
import Foundation
import os.log
import Metal

/// Debug-only memory diagnostics. Toggle: -DebugMemoryDiagnostics YES
enum MemoryDiagnostics {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "DebugMemoryDiagnostics")
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

    // MARK: - os_signpost for Instruments

    static let signpostLog = OSLog(subsystem: "com.animi.memory-diagnostics", category: .pointsOfInterest)

    static func signpostEvent(_ name: StaticString) {
        guard isEnabled else { return }
        os_signpost(.event, log: signpostLog, name: name)
    }
}
#endif
