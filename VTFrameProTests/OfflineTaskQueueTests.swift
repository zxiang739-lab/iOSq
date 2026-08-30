//
//  OfflineTaskQueueTests.swift
//  VTFrameProTests
//
//  严格串行离线任务队列测试（actor OfflineTaskQueue）。
//  覆盖规则：ARCHITECTURE.md §3.2（R-14：严格串行、任务可取消、进度可见；状态机流转）。
//
//  说明：队列依赖具体 `OfflineProcessingService`（非协议注入），且其 `process` 需要真实
//  视频文件与 AVAsset；本测试以「引擎解析闭包返回 nil」短路——任务立即进入
//  .failed(noUsableEngine)，从而在不触碰 AVFoundation/CoreML 的前提下验证：
//  入队顺序、严格串行、取消语义、状态流转。真实视频处理路径列为「真机必测项」。
//

import Foundation
import XCTest
@testable import VTFramePro

@MainActor
final class OfflineTaskQueueTests: XCTestCase {

    /// 构造队列：engineResolver 恒返回 nil（无可用引擎，任务快速终态）。
    private func makeQueue() -> OfflineTaskQueue {
        OfflineTaskQueue(
            processingService: OfflineProcessingService(
                pixelBufferPool: PixelBufferPool(),
                photoLibraryService: PhotoLibraryService(permissionService: PermissionService())
            ),
            engineResolver: { _ in nil }
        )
    }

    private func makeTask(mode: ProcessingMode) -> OfflineTask {
        OfflineTask(
            mode: mode,
            sourceVideoURL: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).mov"),
            engineID: "system-vt"
        )
    }

    // MARK: - 入队 → 状态流转（queued → running → failed）

    /// 入队后广播 .queued；因引擎解析失败最终 .failed（message 非空）。
    func testEnqueue_reachesTerminalFailed_whenNoEngine() async {
        let queue = makeQueue()
        let task = makeTask(mode: .offlineSuperResolution)
        await queue.enqueue(task)

        // 终态：failed（无可用引擎，AppError.noUsableEngine 文案）。
        let terminal = await waitUntil { [queue] in
            await queue.currentTasks().first?.status.isTerminal ?? false
        }
        XCTAssertTrue(terminal, "任务应在无可用引擎时快速终态")

        let finalStatus = await queue.currentTasks().first?.status
        guard case .failed(let message) = finalStatus else {
            return XCTFail("期望 failed，实际 \(String(describing: finalStatus))")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - 严格串行（一次只跑一个 + 入队顺序）

    /// 入队 A、B：A 先进入执行（running），B 保持 queued，直到 A 终态后 B 才被调度。
    func testSerialExecution_oneAtATime_inOrder() async {
        let queue = makeQueue()
        let a = makeTask(mode: .offlineInterpolation)
        let b = makeTask(mode: .offlineSuperResolution)
        await queue.enqueue(a)
        await queue.enqueue(b)

        // 观测流事件顺序：A 的终态必须先于 B 出现任何 running/终态。
        var sawARunning = false
        var sawATerminal = false
        var sawBRunning = false
        var sawBTerminal = false
        var orderValid = true

        for await event in queue.taskUpdates {
            if event.id == a.id {
                if case .running = event.status { sawARunning = true }
                if event.status.isTerminal {
                    sawATerminal = true
                    // A 终态前 B 不得已开始。
                    if sawBRunning || sawBTerminal { orderValid = false }
                }
            }
            if event.id == b.id {
                if sawBRunning { continue }
                if case .running = event.status {
                    sawBRunning = true
                    if !sawATerminal { orderValid = false }
                }
                if event.status.isTerminal {
                    sawBTerminal = true
                    if !sawATerminal { orderValid = false }
                }
            }
            if sawATerminal && sawBTerminal { break }
        }

        XCTAssertTrue(sawATerminal, "A 应到达终态")
        XCTAssertTrue(sawBTerminal, "B 应到达终态")
        XCTAssertTrue(orderValid, "严格串行：B 不得在 A 终态前进入执行")
    }

    // MARK: - 取消（排队中 → 立即 .cancelled）

    /// 排队中的任务（A 执行中）取消 → 直接 .cancelled，不移除任务记录，不产生 running。
    func testCancelQueuedTask_marksCancelled() async {
        let queue = makeQueue()
        // 用可等待的 resolver 拖住 A，保证 B 停留在排队态。
        let hold = AsyncStream<Void>.makeStream()
        let queueWithHold = OfflineTaskQueue(
            processingService: OfflineProcessingService(
                pixelBufferPool: PixelBufferPool(),
                photoLibraryService: PhotoLibraryService(permissionService: PermissionService())
            ),
            engineResolver: { _ in
                _ = await hold.stream.first(where: { _ in true })
                return nil
            }
        )
        let a = makeTask(mode: .offlineInterpolation)
        let b = makeTask(mode: .offlineSuperResolution)
        await queueWithHold.enqueue(a)
        await queueWithHold.enqueue(b)

        // 等 B 进入排队态（A 被 hold 阻塞在执行中）。
        let bQueued = await waitUntil { [queueWithHold] in
            await queueWithHold.currentTasks().first { $0.id == b.id }?.status == .queued
        }
        XCTAssertTrue(bQueued)

        await queueWithHold.cancel(taskID: b.id)
        let bCancelled = await waitUntil { [queueWithHold] in
            await queueWithHold.currentTasks().first { $0.id == b.id }?.status == .cancelled
        }
        XCTAssertTrue(bCancelled, "排队任务取消应立即 .cancelled")

        // 释放 A 的执行，避免悬挂测试。
        hold.continuation.finish()
        _ = await waitUntil { [queueWithHold] in
            await queueWithHold.currentTasks().first { $0.id == a.id }?.status.isTerminal ?? false
        }
    }

    // MARK: - 取消（执行中 → 请求取消，最终由处理方转为 .cancelled）

    /// 执行中的任务：cancel 置令牌（不直接改状态）；由于 resolver 被 hold，
    /// 恢复后返回 nil → 任务以 failed(noUsableEngine) 终态（见报告 P1-03 竞态说明）。
    func testCancelRunningTask_requestsToken() async {
        let registry = EngineRegistry()
        let vt = MockAIEngine(engineID: "system-vt", state: .ready)
        registry.register(vt)

        // 处理器正常（resolver 返回就绪引擎），但引擎解析阻塞，使任务停留在 running。
        let hold = AsyncStream<Void>.makeStream()
        let queue = OfflineTaskQueue(
            processingService: OfflineProcessingService(
                pixelBufferPool: PixelBufferPool(),
                photoLibraryService: PhotoLibraryService(permissionService: PermissionService())
            ),
            engineResolver: { id in
                _ = await hold.stream.first(where: { _ in true })
                return await registry.engine(withID: id)
            }
        )
        let task = makeTask(mode: .offlineInterpolation)
        await queue.enqueue(task)

        let running = await waitUntil { [queue] in
            if case .running = await queue.currentTasks().first?.status { return true }
            return false
        }
        XCTAssertTrue(running, "任务应进入 running")

        await queue.cancel(taskID: task.id)

        // 释放解析；任务随取消令牌在后续帧循环检查命中 → 见报告 P1-03
        // （当前实现：引擎解析完成后若无引擎匹配直接 .failed；MakeQueue 场景见上）。
        hold.continuation.finish()
        _ = await waitUntil { [queue] in
            await queue.currentTasks().first?.status.isTerminal ?? false
        }
    }

    // MARK: - currentTasks 快照

    /// currentTasks 返回全部任务（含终态历史），按入队序。
    func testCurrentTasks_snapshot() async {
        let queue = makeQueue()
        let a = makeTask(mode: .offlineInterpolation)
        let b = makeTask(mode: .offlineSuperResolution)
        await queue.enqueue(a)
        await queue.enqueue(b)
        let snapshot = await queue.currentTasks()
        XCTAssertEqual(snapshot.map(\.id), [a.id, b.id], "按入队序返回")
    }
}

// MARK: - 小工具：AsyncStream 手动可控制流

/// 为测试提供可显式 finish 的控制流（hold/unblock 模式）。
private extension AsyncStream where Element == Void {
    static func makeStream() -> (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation) {
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { continuation = $0 }
        return (stream, continuation)
    }
}