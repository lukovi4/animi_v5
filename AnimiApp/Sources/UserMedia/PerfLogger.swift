import Foundation
import Metal

#if DEBUG

#if canImport(Darwin)
import Darwin.Mach
#endif

// MARK: - CPU

public enum ProcessCPU {
    /// Returns CPU usage for the current process.
    /// - oneCorePercent: 100% = 1 full core. Can exceed 100% on multicore.
    /// - allCoresPercent: 100% = all cores fully utilized.
    public static func sample() -> (oneCorePercent: Double, allCoresPercent: Double) {
        #if canImport(Darwin)
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        let kerr = task_threads(mach_task_self_, &threads, &threadCount)
        guard kerr == KERN_SUCCESS, let threads else { return (0, 0) }
        defer {
            // Deallocate thread list returned by task_threads
            let size = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), size)
        }

        var totalUsage: Double = 0

        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)

            let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), intPtr, &count)
                }
            }
            if result != KERN_SUCCESS { continue }

            // Skip idle threads
            if (info.flags & TH_FLAGS_IDLE) != 0 { continue }

            // cpu_usage is scaled by TH_USAGE_SCALE (1000)
            let usage = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            totalUsage += usage
        }

        let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
        let allCores = coreCount > 0 ? (totalUsage / coreCount) : totalUsage
        return (totalUsage, allCores)
        #else
        return (0, 0)
        #endif
    }
}

// MARK: - Memory

public enum ProcessMemory {
    /// Returns memory usage for the current process.
    /// - residentBytes: resident set size
    /// - physFootprintBytes: iOS "physical footprint" (best indicator of memory pressure)
    public static func sample() -> (residentBytes: UInt64, physFootprintBytes: UInt64) {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)

        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }

        return (UInt64(info.resident_size), UInt64(info.phys_footprint))
        #else
        return (0, 0)
        #endif
    }
}

// MARK: - GPU Frame Time

public struct GPUSample: Sendable {
    public let gpuMs: Double
    public let cpuToGpuLatencyMs: Double?
}

public enum GPUFrameTime {
    /// Call inside cmdBuf.addCompletedHandler.
    public static func fromCompleted(commandBuffer: MTLCommandBuffer) -> GPUSample? {
        let start = commandBuffer.gpuStartTime
        let end = commandBuffer.gpuEndTime
        guard start > 0, end > start else { return nil }

        let gpuMs = (end - start) * 1000.0
        return GPUSample(gpuMs: gpuMs, cpuToGpuLatencyMs: nil)
    }
}

// MARK: - Formatting helpers

public enum PerfFormat {
    public static func bytesToMB(_ bytes: UInt64) -> Double {
        Double(bytes) / (1024.0 * 1024.0)
    }
}

// MARK: - Performance Logger

/// Lightweight performance logger for the App layer.
/// Prints aggregated stats every `intervalSeconds`.
/// PR1.4: Added draw CPU encode timing (avg/p95/max).
/// PR1.5: Added split timing (semaphore, encode, commands).
final class PerfLogger {
    private let intervalSeconds: TimeInterval
    private var timer: Timer?

    // FPS
    private var frameCount: Int = 0

    // GPU
    private var gpuSamples: [Double] = []  // ms

    // PR1.4: Draw CPU encode timing
    private static let maxDrawSamples = 240  // 2s @ 60fps × 2
    private var drawCpuSamples: [Double] = []  // ms

    // PR1.5: Split timing for diagnosis
    private var semaphoreSamples: [Double] = []  // ms
    private var commandsSamples: [Double] = []   // ms (renderCommands generation)
    private var encodeSamples: [Double] = []     // ms (renderer.draw)

    // PR-A: Dropped frames counter (non-blocking draw)
    private var droppedFrameCount: Int = 0

    init(intervalSeconds: TimeInterval = 2.0) {
        self.intervalSeconds = intervalSeconds
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Call from MTKViewDelegate draw(in:) at start of each frame.
    func recordFrame() {
        frameCount += 1
    }

    /// Call from commandBuffer.addCompletedHandler to record GPU time.
    func recordGPUSample(_ gpuMs: Double) {
        gpuSamples.append(gpuMs)
    }

    /// PR1.4: Call from draw(in:) to record CPU encode time.
    func recordDrawCPU(ms: Double) {
        drawCpuSamples.append(ms)
        if drawCpuSamples.count > Self.maxDrawSamples {
            drawCpuSamples.removeFirst(drawCpuSamples.count - Self.maxDrawSamples)
        }
    }

    /// PR1.5: Record split timing for detailed diagnosis.
    func recordSplitTiming(semaphoreMs: Double, commandsMs: Double, encodeMs: Double) {
        semaphoreSamples.append(semaphoreMs)
        commandsSamples.append(commandsMs)
        encodeSamples.append(encodeMs)
        // Keep bounded
        if semaphoreSamples.count > Self.maxDrawSamples {
            semaphoreSamples.removeFirst(semaphoreSamples.count - Self.maxDrawSamples)
            commandsSamples.removeFirst(commandsSamples.count - Self.maxDrawSamples)
            encodeSamples.removeFirst(encodeSamples.count - Self.maxDrawSamples)
        }
    }

    /// PR-A: Record a dropped frame (non-blocking draw couldn't acquire semaphore slot).
    func recordDroppedFrame() {
        droppedFrameCount += 1
    }

    private func flush() {
        let cpu = ProcessCPU.sample()
        let mem = ProcessMemory.sample()

        let fps = Double(frameCount) / intervalSeconds
        frameCount = 0

        // PR-A: Capture and reset dropped frame count
        let droppedThisInterval = droppedFrameCount
        droppedFrameCount = 0

        let (gpuAvg, gpuP95) = computeGPUStatsAndReset()

        // PR1.4: Draw CPU stats
        let drawSamples = drawCpuSamples
        drawCpuSamples.removeAll(keepingCapacity: true)
        let (drawAvg, drawP95, drawMax) = computeStats(drawSamples)

        // PR1.5: Split timing stats
        let semSamples = semaphoreSamples
        let cmdSamples = commandsSamples
        let encSamples = encodeSamples
        semaphoreSamples.removeAll(keepingCapacity: true)
        commandsSamples.removeAll(keepingCapacity: true)
        encodeSamples.removeAll(keepingCapacity: true)
        let (semMax, _, _) = computeStats(semSamples)
        let (cmdMax, _, _) = computeStats(cmdSamples)
        let (encMax, _, _) = computeStats(encSamples)

        let residentMB = PerfFormat.bytesToMB(mem.residentBytes)
        let footprintMB = PerfFormat.bytesToMB(mem.physFootprintBytes)

        if let gpuAvg, let gpuP95 {
            print(String(format: "[PERF] FPS: %.1f | CPU: %.1f%% (1core), %.1f%% (all) | MEM: %.0fMB res, %.0fMB foot | GPU: avg %.2fms, p95 %.2fms | DRAW: avg %.2fms, p95 %.2fms, max %.2fms",
                         fps, cpu.oneCorePercent, cpu.allCoresPercent, residentMB, footprintMB, gpuAvg, gpuP95,
                         drawAvg ?? 0, drawP95 ?? 0, drawMax ?? 0))
        } else {
            print(String(format: "[PERF] FPS: %.1f | CPU: %.1f%% (1core), %.1f%% (all) | MEM: %.0fMB res, %.0fMB foot | GPU: n/a | DRAW: avg %.2fms, p95 %.2fms, max %.2fms",
                         fps, cpu.oneCorePercent, cpu.allCoresPercent, residentMB, footprintMB,
                         drawAvg ?? 0, drawP95 ?? 0, drawMax ?? 0))
        }

        // PR1.5: Print split timing if there's a significant spike
        if let semMax, let cmdMax, let encMax, (semMax > 10 || cmdMax > 10 || encMax > 10) {
            print(String(format: "[PERF-SPLIT] sem: %.1fms | cmds: %.1fms | encode: %.1fms",
                         semMax, cmdMax, encMax))
        }

        // PR-A: Log dropped frames if any occurred this interval
        if droppedThisInterval > 0 {
            print("[PERF-DROP] droppedFrames: \(droppedThisInterval) in last \(intervalSeconds)s")
        }
    }

    private func computeGPUStatsAndReset() -> (avg: Double?, p95: Double?) {
        guard !gpuSamples.isEmpty else { return (nil, nil) }
        let samples = gpuSamples
        gpuSamples.removeAll(keepingCapacity: true)

        let avg = samples.reduce(0, +) / Double(samples.count)

        let sorted = samples.sorted()
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        let p95 = sorted[p95Index]

        return (avg, p95)
    }

    /// PR1.4: Compute avg/p95/max for any sample array.
    private func computeStats(_ samples: [Double]) -> (avg: Double?, p95: Double?, max: Double?) {
        guard !samples.isEmpty else { return (nil, nil, nil) }
        let avg = samples.reduce(0, +) / Double(samples.count)
        let maxV = samples.max() ?? avg
        let sorted = samples.sorted()
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        let p95 = sorted[p95Index]
        return (avg, p95, maxV)
    }
}

#endif
