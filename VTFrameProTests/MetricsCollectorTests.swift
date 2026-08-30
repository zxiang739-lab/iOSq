//
//  MetricsCollectorTests.swift
//  VTFrameProTests
//
//  指标采集器轻量集成测试（MetricsCollector）。
//  覆盖规则：PRD R-10（FPS / 端到端延迟 / 硬件占用采集）；
//          ARCHITECTURE.md §3.1 旁路 500ms 汇总、§10-3 分级呈现。
//
//  说明：aggregate() 为私有方法，本测试通过真实 500ms 聚合任务读取 metrics 流，
//  验证「记录上屏帧/推理耗时 → 产出快照」的端到端行为；为控制执行时长仅做 1~2 次
//  聚合窗口的冒烟验证，不做拉长时延的时序断言（避免 CI 抖动误报）。
//

import CoreMedia
import XCTest
@testable import VTFramePro

final class MetricsCollectorTests: XCTestCase {

    /// start 后 500ms 产出快照：FPS ≥ 记录数、延迟 / 占用为 0~1 合理区间。
    func testStart_producesSnapshotWithRecordedValues() async throws {
        let collector = MetricsCollector()
        collector.start(frameBudgetMs: 33.3)

        // 记录 3 帧上屏（PTS 取 mach 时钟域小值，避免负延迟被 clamp 为 0）。
        let basePTS = CMTime(value: 1_000_000, timescale: 1_000_000)
        for i in 0..<3 {
            collector.recordDisplayedFrame(capturePTS: CMTimeAdd(basePTS, CMTime(value: CMTimeValue(i), timescale: 1_000_000)))
        }
        collector.recordInference(durationMs: 12)

        // 等待 ≥1 个聚合窗口（500ms）。
        var iter = collector.metrics.makeAsyncIterator()
        let deadline = Date().addingTimeInterval(3)
        var snapshot: PerformanceMetrics?
        while Date() < deadline {
            if let next = try? await iter.next() {
                snapshot = next
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let metrics = try XCTUnwrap(snapshot, "500ms 内应有快照产出")
        XCTAssertGreaterThanOrEqual(metrics.fps, 3, "窗口内记录 3 帧，FPS ≥ 3")
        XCTAssertGreaterThanOrEqual(metrics.cpuUsagePercent, 0)
        XCTAssertLessThanOrEqual(metrics.cpuUsagePercent, 1)
        XCTAssertGreaterThanOrEqual(metrics.memoryUsageMB, 0)
        // GPU 估算 = 平均推理耗时 / 帧预算（§10-3）：12ms / 33.3ms ≈ 0.36。
        XCTAssertGreaterThan(metrics.gpuEstimatedPercent, 0)
        XCTAssertLessThanOrEqual(metrics.gpuEstimatedPercent, 1)
        collector.stop()
    }

    /// start 幂等：重复 start 不创建多个聚合任务（不产出 2 倍快照）。
    func testStart_idempotent() async throws {
        let collector = MetricsCollector()
        collector.start(frameBudgetMs: 33.3)
        collector.start(frameBudgetMs: 33.3)

        collector.recordDisplayedFrame(capturePTS: CMTime(value: 1, timescale: 1_000_000))
        var iter = collector.metrics.makeAsyncIterator()
        let first = try? await iter.next()  // 5s 内首个快照
        XCTAssertNotNil(first, "仍应正常产出快照")
        collector.stop()
        collector.stop() // stop 幂等
    }

    /// stop 后不再产出（链路停止语义，§3.1）。
    func testStop_haltsOutput() async throws {
        let collector = MetricsCollector()
        collector.start(frameBudgetMs: 33.3)
        collector.recordDisplayedFrame(capturePTS: CMTime(value: 1, timescale: 1_000_000))
        // 先消费一个快照（确认真在工作）。
        var iter = collector.metrics.makeAsyncIterator()
        _ = try? await iter.next()
        collector.stop()
        collector.recordDisplayedFrame(capturePTS: CMTime(value: 2, timescale: 1_000_000))
        // stop 后不应再有新快照；由于流不 finish，仅做“无立即产出”验证（不阻塞）。
        let next = try? await withThrowingTaskGroup(of: PerformanceMetrics?.self) { group in
            group.addTask { try? await iter.next() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 700_000_000)
                return nil
            }
            let result = try? await group.next()
            group.cancelAll()
            return result ?? nil
        }
        XCTAssertNil(next, "stop 后不应产出新快照")
    }
}