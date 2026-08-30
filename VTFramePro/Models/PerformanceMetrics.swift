//
//  PerformanceMetrics.swift
//  VTFramePro
//
//  实时链路性能指标值类型（L5 Model 层）。
//  对应 PRD R-10 与 ARCHITECTURE.md §3.1 指标采集、§10-3 分级呈现结论。
//

import Foundation

/// 实时链路一帧性能指标快照。
///
/// 采集口径（§10-3 分级呈现）：
/// - `fps` / `endToEndLatencyMs` / `cpuUsagePercent` / `memoryUsageMB`：公开 API 精确采集；
/// - `gpuEstimatedPercent`：GPU/ANE 无公开精确计数 API，以「推理耗时占帧预算比 +
///   Metal command buffer GPU 执行时长」估算，UI 必须标注「估算」。
struct PerformanceMetrics: Sendable, Equatable {
    /// 输出帧率（DisplayLink 上屏计数滑动窗口，单位 fps）。
    var fps: Double
    /// 端到端延迟（采集 PTS 与上屏时刻差值滑动平均，单位 ms；目标 <150ms）。
    var endToEndLatencyMs: Double
    /// App 进程 CPU 占用率（0~1，task_info/host_processor_info 采样）。
    var cpuUsagePercent: Double
    /// App 进程物理内存占用（MB，task_vm_info 采样）。
    var memoryUsageMB: Double
    /// GPU/ANE 占用估算（0~1，估算值，UI 标注）。
    var gpuEstimatedPercent: Double
    /// 是否达到 <150ms 延迟目标。
    var meetsLatencyBudget: Bool {
        endToEndLatencyMs < 150
    }

    /// 零值快照（未启动时的面板占位）。
    static let zero = PerformanceMetrics(
        fps: 0,
        endToEndLatencyMs: 0,
        cpuUsagePercent: 0,
        memoryUsageMB: 0,
        gpuEstimatedPercent: 0
    )
}
