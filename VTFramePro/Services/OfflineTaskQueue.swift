//
//  OfflineTaskQueue.swift
//  VTFramePro
//
//  严格串行任务队列 + 取消传播（L3 媒体服务层，actor）。
//  对应 ARCHITECTURE.md §3.2（R-14：严格串行、任务可取消、进度可见）。
//

import Foundation
import OSLog

/// 离线任务串行队列。
///
/// 语义：
/// - maxConcurrency = 1：一次只执行一个任务，其余排队（R-14）；
/// - 取消传播：UI cancel → 本队列置令牌 → 帧循环检查点命中 →
///   writer.cancelWriting() → 清理临时文件 → 状态 .cancelled（不弹错误窗）；
/// - 进度可见：每帧进度经 `taskUpdates` 广播给 ViewModel。
///
/// 线程：actor 隔离队列状态；`taskUpdates` 流为非隔离属性，可任意上下文订阅。
actor OfflineTaskQueue {

    // MARK: - 输出

    /// 任务状态流（入队/进度/终态全量快照逐条广播）。
    nonisolated let taskUpdates: AsyncStream<OfflineTask>

    // MARK: - 依赖

    /// 处理服务（协议注入，构造于 DI 容器）。
    private let processingService: OfflineProcessingService
    /// 引擎解析闭包（engineID → 协议引擎；由 DI 桥接 EngineRegistry，§1.2 第 4 条）。
    private let engineResolver: @Sendable (String) async -> (any AIEngine)?

    // MARK: - 队列状态（actor 隔离）

    /// 全部任务（含历史终态，按创建序）。
    private var tasks: [OfflineTask] = []
    /// 等待执行的任务 ID 队列。
    private var pendingIDs: [UUID] = []
    /// 当前执行中任务 ID。
    private var runningID: UUID?
    /// 各任务取消令牌。
    private var cancelTokens: [UUID: ProcessingCancelToken] = [:]
    /// 串行调度任务句柄。
    private var runnerTask: Task<Void, Never>?

    private let streamContinuation: AsyncStream<OfflineTask>.Continuation
    private let logger = Logger(subsystem: "com.vtframepro", category: "offline")

    // MARK: - 初始化

    init(processingService: OfflineProcessingService,
         engineResolver: @escaping @Sendable (String) async -> (any AIEngine)?) {
        self.processingService = processingService
        self.engineResolver = engineResolver
        var continuation: AsyncStream<OfflineTask>.Continuation!
        self.taskUpdates = AsyncStream { continuation = $0 }
        self.streamContinuation = continuation
    }

    // MARK: - 入队

    /// 任务入队（广播 .queued；若空闲立即调度）。
    func enqueue(_ task: OfflineTask) {
        tasks.append(task)
        pendingIDs.append(task.id)
        cancelTokens[task.id] = ProcessingCancelToken()
        streamContinuation.yield(task)
        logger.notice("任务入队: \(task.sourceFileName) [\(task.mode.displayName)]")
        scheduleNextIfIdle()
    }

    // MARK: - 取消

    /// 取消任务：
    /// - 排队中：直接移除并广播 .cancelled；
    /// - 执行中：置令牌，帧循环检查点命中后广播 .cancelled（§3.2 取消传播）。
    func cancel(taskID: UUID) {
        if let index = pendingIDs.firstIndex(of: taskID) {
            pendingIDs.remove(at: index)
            updateStatus(taskID: taskID, status: .cancelled)
            logger.notice("排队任务已取消: \(taskID)")
            return
        }
        if runningID == taskID {
            cancelTokens[taskID]?.cancel()
            logger.notice("执行中任务已请求取消: \(taskID)")
        }
    }

    // MARK: - 查询

    /// 全部任务快照（ViewModel 初始化拉取）。
    func currentTasks() -> [OfflineTask] {
        tasks
    }

    // MARK: - 私有：串行调度

    /// 空闲时取出下一个排队任务执行（严格串行的核心）。
    private func scheduleNextIfIdle() {
        guard runnerTask == nil, !pendingIDs.isEmpty else { return }
        runnerTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    /// 串行执行循环：逐个取出排队任务直至队列清空。
    private func runLoop() async {
        while let nextID = nextPendingID() {
            runningID = nextID
            await execute(taskID: nextID)
            runningID = nil
        }
        runnerTask = nil
    }

    /// 取出下一个排队任务（同步原语，actor 内调用）。
    private func nextPendingID() -> UUID? {
        guard !pendingIDs.isEmpty else { return nil }
        return pendingIDs.removeFirst()
    }

    // MARK: - 私有：单任务执行

    /// 执行单个任务（状态机：running(progress) → completed/failed/cancelled）。
    private func execute(taskID: UUID) async {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        updateStatus(taskID: taskID, status: .running(progress: 0))

        // 引擎解析（engineID → 协议引擎；注册表跨界桥接由 DI 闭包完成）。
        guard let engine = await engineResolver(task.engineID) else {
            let capability: EngineCapability = task.mode == .offlineInterpolation
                ? .frameInterpolation : .superResolution
            let error = AppError.noUsableEngine(capability: capability)
            updateStatus(taskID: taskID,
                         status: .failed(message: error.errorDescription ?? "无可用引擎"))
            return
        }

        let token = cancelTokens[taskID] ?? ProcessingCancelToken()
        cancelTokens[taskID] = token

        do {
            let outputURL = try await processingService.process(
                task: task,
                engine: engine,
                cancelToken: token
            ) { [weak self] progress in
                // 进度广播（@Sendable 跨域回调 → actor 异步提交）。
                Task { [weak self] in
                    await self?.updateStatus(taskID: taskID, status: .running(progress: progress))
                }
            }
            updateStatus(taskID: taskID, status: .completed(outputURL: outputURL))
        } catch let error as AppError {
            switch error {
            case .cancelled:
                // 取消属正常状态机，不记失败（§8.2）。
                updateStatus(taskID: taskID, status: .cancelled)
            default:
                updateStatus(taskID: taskID,
                             status: .failed(message: error.errorDescription ?? "处理失败"))
            }
        } catch {
            updateStatus(taskID: taskID,
                         status: .failed(message: error.localizedDescription))
        }
        cancelTokens.removeValue(forKey: taskID)
    }

    // MARK: - 私有：状态更新与广播

    /// 更新任务状态并向流广播快照。
    private func updateStatus(taskID: UUID, status: OfflineTaskStatus) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        // 终态保护：已终态任务不再变更（取消竞态防护）。
        if tasks[index].status.isTerminal { return }
        tasks[index].status = status
        streamContinuation.yield(tasks[index])
    }
}
