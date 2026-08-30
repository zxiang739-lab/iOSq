//
//  OfflineTaskTests.swift
//  VTFrameProTests
//
//  离线任务模型 + 状态机测试（OfflineTaskStatus / OfflineTask）。
//  覆盖规则：ARCHITECTURE.md §3.2（状态机：queued → running → cancelled/failed/completed；
//          cancelled 属正常用户行为不弹错误窗，§8.2）；R-14。
//

import Foundation
import XCTest
@testable import VTFramePro

final class OfflineTaskTests: XCTestCase {

    // MARK: - OfflineTaskStatus.isTerminal（终态保护：终态后不再变更）

    func testIsTerminal_onlyTerminalStates() {
        XCTAssertFalse(OfflineTaskStatus.queued.isTerminal)
        XCTAssertFalse(OfflineTaskStatus.running(progress: 0).isTerminal)
        XCTAssertFalse(OfflineTaskStatus.running(progress: 1).isTerminal)
        XCTAssertTrue(OfflineTaskStatus.cancelled.isTerminal)
        XCTAssertTrue(OfflineTaskStatus.failed(message: "x").isTerminal)
        XCTAssertTrue(OfflineTaskStatus.completed(outputURL: URL(fileURLWithPath: "/tmp/a.mp4")).isTerminal)
    }

    // MARK: - 状态迁移合法性（§3.2）

    /// 一次合法生命周期：queued → running → completed。
    func testLifecycle_queuedRunningCompleted() {
        var status: OfflineTaskStatus = .queued
        XCTAssertFalse(status.isTerminal)
        status = .running(progress: 0.25)
        XCTAssertFalse(status.isTerminal)
        status = .completed(outputURL: URL(fileURLWithPath: "/tmp/out.mp4"))
        XCTAssertTrue(status.isTerminal)
    }

    /// 取消终态（正常用户行为，不弹窗由 AppError.cancelled 表达，§8.2）。
    func testLifecycle_cancelled_isTerminal() {
        var status: OfflineTaskStatus = .queued
        status = .running(progress: 0.5)
        status = .cancelled
        XCTAssertTrue(status.isTerminal)
    }

    /// 失败终态：附 AppError 友好文案。
    func testLifecycle_failed_isTerminal() {
        var status: OfflineTaskStatus = .queued
        status = .failed(message: "处理失败（x）")
        XCTAssertTrue(status.isTerminal)
    }

    // MARK: - displayName（进度百分比格式 / 终态文案）

    func testDisplayName_queued_and_running() {
        XCTAssertEqual(OfflineTaskStatus.queued.displayName, "排队中")
        XCTAssertEqual(OfflineTaskStatus.running(progress: 0).displayName, "处理中 0%")
        XCTAssertEqual(OfflineTaskStatus.running(progress: 0.5).displayName, "处理中 50%")
        XCTAssertEqual(OfflineTaskStatus.running(progress: 1).displayName, "处理中 100%")
    }

    func testDisplayName_terminal() {
        XCTAssertEqual(OfflineTaskStatus.cancelled.displayName, "已取消")
        XCTAssertEqual(OfflineTaskStatus.completed(outputURL: URL(fileURLWithPath: "/a")).displayName,
                       "已完成")
        XCTAssertEqual(OfflineTaskStatus.failed(message: "内存不足").displayName, "失败：内存不足")
    }

    // MARK: - 值语义与等值（跨 actor 传递值类型，Identifiable）

    func testOfflineTask_valueSemantics() {
        let url = URL(fileURLWithPath: "/tmp/src.mov")
        let a = OfflineTask(mode: .offlineInterpolation, sourceVideoURL: url, engineID: "system-vt")
        var b = a
        b.status = .running(progress: 0.5)
        // a 不应受 b 影响（值类型）。
        XCTAssertEqual(a.status, .queued)
        XCTAssertEqual(b.status, .running(progress: 0.5))
    }

    /// 构造即 queued（§3.2 入队态）。
    func testOfflineTask_initStatusIsQueued() {
        let task = OfflineTask(mode: .offlineSuperResolution,
                               sourceVideoURL: URL(fileURLWithPath: "/tmp/x.mov"),
                               engineID: "coreml-<UUID>")
        XCTAssertEqual(task.status, .queued)
    }

    /// 仅离线模式承载（ViewModel 层保证，R-04/R-05）。
    func testOfflineTask_modes_areOfflineOnly() {
        let task = OfflineTask(mode: .offlineInterpolation,
                               sourceVideoURL: URL(fileURLWithPath: "/tmp/a.mov"),
                               engineID: "system-vt")
        XCTAssertFalse(task.mode.isRealtime)
    }

    /// sourceFileName 取 lastPathComponent（列表展示，§3.2）。
    func testSourceFileName_lastPathComponent() {
        let task = OfflineTask(mode: .offlineInterpolation,
                               sourceVideoURL: URL(fileURLWithPath: "/tmp/剪映素材.mov"),
                               engineID: "system-vt")
        XCTAssertEqual(task.sourceFileName, "剪映素材.mov")
    }

    /// createdAt 默认注入；同输入不同实例不等（UUID 不同）。
    func testOfflineTask_distinctByUUID() {
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        let a = OfflineTask(mode: .offlineInterpolation, sourceVideoURL: url, engineID: "system-vt")
        let b = OfflineTask(mode: .offlineInterpolation, sourceVideoURL: url, engineID: "system-vt")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)
    }

    /// Codable：任务列表不持久化，但值类型保持可编码（供未来 R-23 历史记录）。
    func testOfflineTask_codableRoundTrip() throws {
        let task = OfflineTask(mode: .offlineInterpolation,
                               sourceVideoURL: URL(fileURLWithPath: "/tmp/a.mov"),
                               engineID: "system-vt")
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(OfflineTask.self, from: data)
        XCTAssertEqual(decoded, task)
    }
}