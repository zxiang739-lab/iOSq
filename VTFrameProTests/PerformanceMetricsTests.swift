//
//  PerformanceMetricsTests.swift
//  VTFrameProTests
//
//  实时链路性能指标值类型测试。
//  覆盖规则：PRD R-10（端到端延迟目标 <150ms）；ARCHITECTURE.md §10-3（GPU/ANE 估算）；
//          §3.1 指标采集口径。
//

import XCTest
@testable import VTFramePro

final class PerformanceMetricsTests: XCTestCase {

    // MARK: - 延迟预算（目标 <150ms，R-10）

    func testMeetsLatencyBudget_below150() {
        let metrics = PerformanceMetrics(fps: 60, endToEndLatencyMs: 149.9,
                                         cpuUsagePercent: 0.3, memoryUsageMB: 200,
                                         gpuEstimatedPercent: 0.4)
        XCTAssertTrue(metrics.meetsLatencyBudget)
    }

    func testMeetsLatencyBudget_atAndAbove150() {
        let at = PerformanceMetrics(fps: 60, endToEndLatencyMs: 150,
                                    cpuUsagePercent: 0.3, memoryUsageMB: 200,
                                    gpuEstimatedPercent: 0.4)
        XCTAssertFalse(at.meetsLatencyBudget, "150ms 不达标（规格为严格 <150ms）")

        let over = PerformanceMetrics(fps: 30, endToEndLatencyMs: 180,
                                      cpuUsagePercent: 0.8, memoryUsageMB: 500,
                                      gpuEstimatedPercent: 0.9)
        XCTAssertFalse(over.meetsLatencyBudget)
    }

    // MARK: - 零值占位（未启动时面板占位，§3.1）

    func testZeroSnapshot() {
        XCTAssertEqual(PerformanceMetrics.zero.fps, 0)
        XCTAssertEqual(PerformanceMetrics.zero.endToEndLatencyMs, 0)
        XCTAssertEqual(PerformanceMetrics.zero.cpuUsagePercent, 0)
        XCTAssertEqual(PerformanceMetrics.zero.memoryUsageMB, 0)
        XCTAssertEqual(PerformanceMetrics.zero.gpuEstimatedPercent, 0)
    }

    // MARK: - 值语义 / 等值

    func testMetrics_equatable() {
        let a = PerformanceMetrics(fps: 60, endToEndLatencyMs: 120,
                                   cpuUsagePercent: 0.2, memoryUsageMB: 100,
                                   gpuEstimatedPercent: 0.5)
        let b = PerformanceMetrics(fps: 60, endToEndLatencyMs: 120,
                                   cpuUsagePercent: 0.2, memoryUsageMB: 100,
                                   gpuEstimatedPercent: 0.5)
        XCTAssertEqual(a, b)
    }

    /// 占用指标为 0~1 分数语义（UI 按百分比呈现，GlassStatusPanel 钳制）。
    func testUsageFractionSemantics() {
        let metrics = PerformanceMetrics(fps: 30, endToEndLatencyMs: 90,
                                         cpuUsagePercent: 0.45, memoryUsageMB: 300,
                                         gpuEstimatedPercent: 0.67)
        XCTAssertLessThanOrEqual(metrics.cpuUsagePercent, 1)
        XCTAssertGreaterThanOrEqual(metrics.cpuUsagePercent, 0)
        // GPU/ANE 估算值（§10-3 UI 标注「估算」）。
        XCTAssertGreaterThan(metrics.gpuEstimatedPercent, 0.5)
    }
}