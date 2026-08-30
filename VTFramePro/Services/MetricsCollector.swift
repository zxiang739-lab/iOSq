//
//  MetricsCollector.swift
//  VTFramePro
//
//  FPS / 端到端延迟 / 硬件占用采集与 500ms 汇总推送（L3 媒体服务层）。
//  对应 PRD R-10 与 ARCHITECTURE.md §3.1 旁路指标、§10-3 分级呈现结论。
//

import Foundation
import CoreMedia
import OSLog

/// 实时链路指标采集器。
///
/// 采集口径（§10-3，全部公开 API）：
/// - FPS：上屏计数滑动窗口（1s）；
/// - 端到端延迟：采集 `CMSampleBuffer.presentationTimeStamp` 与上屏时刻差值滑动平均；
/// - CPU：`task_threads` + `thread_info(THREAD_BASIC_INFO)` 汇总（Darwin 公开）；
/// - 内存：`task_info(TASK_VM_INFO).phys_footprint`；
/// - GPU/ANE：无公开精确计数 API → 推理耗时占帧预算比估算（UI 标注「估算」）。
///
/// 线程：记录方法可从任意线程调用（采集队列/推理域/DisplayLink），
/// 内部状态 NSLock 保护；聚合任务每 500ms 产出一次快照进 `metrics` 流。
final class MetricsCollector: @unchecked Sendable {

    // MARK: - 输出

    /// 指标流（500ms 一个快照；`start` 后开始产出）。
    let metrics: AsyncStream<PerformanceMetrics>

    // MARK: - 私有状态

    private let continuation: AsyncStream<PerformanceMetrics>.Continuation
    private let lock = NSLock()
    /// 上屏时刻滑动窗口（秒，CFAbsoluteTime）。
    private var displayTimestamps: [CFAbsoluteTime] = []
    /// 端到端延迟滑动窗口（ms）。
    private var latenciesMs: [Double] = []
    /// 窗口内推理耗时累计（ms）与次数（GPU 占用估算用）。
    private var inferenceDurationSumMs: Double = 0
    private var inferenceCount: Int = 0
    /// 帧预算（ms，GPU 占用估算分母；补帧 2× 节拍时约 16.7ms）。
    private var frameBudgetMs: Double = 33.3
    private var aggregationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.vtframepro", category: "media")

    /// 滑动窗口容量（约 2s 数据量）。
    private static let windowCapacity = 120

    // MARK: - 初始化

    init() {
        var continuation: AsyncStream<PerformanceMetrics>.Continuation!
        self.metrics = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    deinit {
        aggregationTask?.cancel()
        continuation.finish()
    }

    // MARK: - 启停

    /// 启动 500ms 聚合任务（幂等）。
    /// - Parameter frameBudgetMs: 帧预算（GPU 占用估算分母）。
    func start(frameBudgetMs: Double = 33.3) {
        lock.withLock {
            guard aggregationTask == nil else { return }
            self.frameBudgetMs = frameBudgetMs
            displayTimestamps.removeAll()
            latenciesMs.removeAll()
            inferenceDurationSumMs = 0
            inferenceCount = 0
        }
        aggregationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.continuation.yield(self.aggregate())
            }
        }
    }

    /// 停止聚合（幂等；流保持存活供下次启动复用）。
    func stop() {
        lock.withLock {
            aggregationTask?.cancel()
            aggregationTask = nil
        }
    }

    // MARK: - 记录（任意线程）

    /// 记录一帧上屏（DisplayLink 输出节拍处调用）。
    /// - Parameter capturePTS: 该帧采集时刻的 PTS（延迟计算锚点）。
    func recordDisplayedFrame(capturePTS: CMTime) {
        let now = CFAbsoluteTimeGetCurrent()
        // 相机帧 PTS 与 mach_absolute_time 同属 mach 时钟域（hostTime），
        // 端到端延迟 = 当前 mach 时刻 - 采集 PTS。
        let captureSeconds = CMTimeGetSeconds(capturePTS)
        let latencyMs: Double? = captureSeconds.isFinite && captureSeconds > 0
            ? max(0, (uptimeSeconds() - captureSeconds) * 1000)
            : nil
        lock.withLock {
            displayTimestamps.append(now)
            if displayTimestamps.count > Self.windowCapacity {
                displayTimestamps.removeFirst(displayTimestamps.count - Self.windowCapacity)
            }
            if let latencyMs {
                latenciesMs.append(latencyMs)
                if latenciesMs.count > Self.windowCapacity {
                    latenciesMs.removeFirst(latenciesMs.count - Self.windowCapacity)
                }
            }
        }
    }

    /// 记录一次推理耗时（推理完成处调用）。
    /// - Parameter durationMs: 推理耗时（ms）。
    func recordInference(durationMs: Double) {
        lock.withLock {
            inferenceDurationSumMs += durationMs
            inferenceCount += 1
        }
    }

    // MARK: - 私有：聚合

    /// 汇总当前窗口为一份快照。
    private func aggregate() -> PerformanceMetrics {
        let (timestamps, latencies, inferenceSum, inferenceN, budget) = lock.withLock {
            let snapshot = (displayTimestamps, latenciesMs,
                            inferenceDurationSumMs, inferenceCount, frameBudgetMs)
            inferenceDurationSumMs = 0
            inferenceCount = 0
            return snapshot
        }

        // FPS：最近 1s 窗口内上屏帧数。
        let now = CFAbsoluteTimeGetCurrent()
        let recentFrames = timestamps.filter { now - $0 <= 1.0 }.count

        // 端到端延迟：滑动平均。
        let averageLatency = latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count)

        // GPU/ANE 占用估算：平均推理耗时 / 帧预算（§10-3，UI 标注估算）。
        let averageInference = inferenceN > 0 ? inferenceSum / Double(inferenceN) : 0
        let gpuEstimate = min(1.0, averageInference / max(budget, 1))

        return PerformanceMetrics(
            fps: Double(recentFrames),
            endToEndLatencyMs: averageLatency,
            cpuUsagePercent: Self.processCPUUsage(),
            memoryUsageMB: Self.physicalFootprintMB(),
            gpuEstimatedPercent: gpuEstimate
        )
    }

    // MARK: - 私有：系统采样（Darwin 公开 API）

    /// 当前进程 CPU 占用率（0~1；task_threads + thread_info 汇总）。
    private static func processCPUUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: threadList),
                          vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_act_t>.stride))
        }
        var totalUsage: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.stride
                                                   / MemoryLayout<integer_t>.stride)
            let result = withUnsafeMutablePointer(to: &info) { infoPointer in
                infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { intPointer in
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO),
                                intPointer, &infoCount)
                }
            }
            guard result == KERN_SUCCESS else { continue }
            // cpu_usage 以 TH_USAGE_SCALE(1000) 为 100% 刻度；flags 排除 idle。
            if (info.flags & TH_FLAGS_IDLE) == 0 {
                totalUsage += Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
            }
        }
        return min(1.0, totalUsage)
    }

    /// 当前进程物理内存占用（MB；task_info TASK_VM_INFO phys_footprint）。
    private static func physicalFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride
                                           / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// 系统启动至今秒数（mach 时钟域，与采集 PTS 同域）。
    private func uptimeSeconds() -> CFAbsoluteTime {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanos = mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom)
        return CFAbsoluteTime(nanos) / 1_000_000_000
    }
}
