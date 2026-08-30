//
//  GlassStatusPanel.swift
//  VTFramePro
//
//  液态玻璃指标面板：FPS / 端到端延迟 / 硬件占用（L1 视图层公共组件）。
//  对应 PRD R-10 与 ARCHITECTURE.md §10-3（GPU/ANE 为估算值，UI 明确标注）。
//

import SwiftUI

/// 实时链路性能状态面板。
///
/// 三项指标 + 延迟达标指示：
/// - FPS（输出帧率）；
/// - 端到端延迟（ms，目标 <150ms，超标变红）；
/// - 硬件占用：CPU / 内存 / GPU·ANE（估算值标注，§10-3）。
struct GlassStatusPanel: View {

    /// 最新指标快照（ViewModel 500ms 推送）。
    let metrics: PerformanceMetrics

    var body: some View {
        HStack(spacing: 0) {
            metricCell(
                title: "FPS",
                value: String(format: "%.0f", metrics.fps),
                tint: .primary
            )
            divider
            metricCell(
                title: "延迟",
                value: String(format: "%.0fms", metrics.endToEndLatencyMs),
                tint: metrics.meetsLatencyBudget ? .primary : .red
            )
            divider
            metricCell(
                title: "CPU",
                value: Self.percentText(metrics.cpuUsagePercent),
                tint: .primary
            )
            divider
            metricCell(
                title: "内存",
                value: String(format: "%.0fMB", metrics.memoryUsageMB),
                tint: .primary
            )
            divider
            metricCell(
                title: "GPU·ANE*",
                value: Self.percentText(metrics.gpuEstimatedPercent),
                tint: .secondary
            )
        }
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("性能面板：帧率 \(Int(metrics.fps))，延迟 \(Int(metrics.endToEndLatencyMs)) 毫秒")
    }

    // MARK: - 子视图

    private func metricCell(title: String, value: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(width: 1, height: 24)
    }

    // MARK: - 文案

    private static func percentText(_ fraction: Double) -> String {
        String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }
}

// MARK: - 图例说明

/// 「* GPU·ANE 为估算值」图例（面板下方小字，§10-3 分级呈现约定）。
struct MetricsEstimationFootnote: View {
    var body: some View {
        Text("* GPU·ANE 占用为估算值（无公开精确计数 API）")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
