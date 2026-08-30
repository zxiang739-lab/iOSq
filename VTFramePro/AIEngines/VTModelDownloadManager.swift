//
//  VTModelDownloadManager.swift
//  VTFramePro
//
//  系统 VT 模型下载三态管理与重试（L4 AI 引擎协议层）。
//  对应 ARCHITECTURE.md §3.3-4 与 §10-2 重试策略（R-30）。
//
//  ※SDK 说明：WWDC25/26 公开资料中，VTFrameProcessor 的系统模型由系统在
//  `startSession(configuration:)` / 首次处理时按需加载（头文件注明
//  "ML model loading may take longer than a frame time"）。截至 Xcode 26 SDK，
//  尚无独立的公开下载进度 API。因此本管理器将「会话建立/模型加载阶段」桥接为
//  三态流：进入准备 → .modelDownloading(progress: 0)（不确定进度，UI 转菊花）；
//  成功 → .ready；失败 → .downloadFailed(message)。若后续 SDK 开放下载进度
//  回调，仅需在本文件内接入真实进度，对外三态契约不变。
//

import Foundation
import OSLog

/// 系统 VT 模型下载三态管理器。
///
/// 职责：
/// - 将引擎的准备操作（可能触发系统模型下载/加载）包装为
///   `.modelDownloading` → `.ready` / `.downloadFailed` 三态流；
/// - 自动重试：仅网络型失败自动重试，最多 2 次，指数退避 5s → 15s（§10-2）；
/// - 手动重试：暴露 `retry()` 供 UI「重试」按钮调用；
/// - `reset()` 取消挂起的自动重试（链路停止 / 退后台即停）。
///
/// 线程：内部状态由 NSLock 保护，可在任意线程调用（`@unchecked Sendable`）。
final class VTModelDownloadManager: @unchecked Sendable {

    // MARK: - 公开状态

    /// 当前三态快照（.checking / .modelDownloading / .downloadFailed / .ready）。
    private(set) var status: EngineState {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }

    /// 三态流（桥接为引擎的 stateUpdates 组成部分）。
    let statusUpdates: AsyncStream<EngineState>

    // MARK: - 私有状态

    private let lock = NSLock()
    private var _status: EngineState = .checking
    private let continuation: AsyncStream<EngineState>.Continuation
    /// 最近一次准备操作（供手动/自动重试复跑）。
    private var lastOperation: (@Sendable () async throws -> Void)?
    /// 已发生的自动重试次数（上限 2，§10-2）。
    private var autoRetryCount: Int = 0
    /// 挂起的自动重试任务（退后台/链路停止时取消）。
    private var pendingRetryTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.vtframepro", category: "engine")

    /// 自动重试退避序列（秒）：5s → 15s。
    private static let backoffSeconds: [UInt64] = [5, 15]

    // MARK: - 初始化

    init() {
        var continuation: AsyncStream<EngineState>.Continuation!
        self.statusUpdates = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    // MARK: - 准备执行（三态桥接）

    /// 执行准备操作并桥接三态。
    ///
    /// 流程：置 `.modelDownloading(progress: 0)` → 执行 operation →
    /// 成功置 `.ready`；失败置 `.downloadFailed` 并按策略调度自动重试。
    ///
    /// - Parameter operation: 引擎的准备闭包（VT 会话建立/模型加载）。
    /// - Throws: operation 抛出的错误原样上抛（引擎据此置自身 state）。
    func runPreparation(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        lock.withLock {
            lastOperation = operation
            pendingRetryTask?.cancel()
            pendingRetryTask = nil
        }
        emit(.modelDownloading(progress: 0))
        do {
            try await operation()
            emit(.ready)
            lock.withLock { autoRetryCount = 0 }
        } catch {
            emit(.downloadFailed(message: error.localizedDescription))
            scheduleAutoRetryIfNeeded(for: error)
            throw error
        }
    }

    // MARK: - 手动重试

    /// 手动重试（UI「重试」按钮）。复跑最近一次准备操作。
    /// 无已记录操作时直接返回。
    func retry() async {
        let operation = lock.withLock { () -> (@Sendable () async throws -> Void)? in
            autoRetryCount = 0 // 手动重试重置自动重试配额
            return lastOperation
        }
        guard let operation else { return }
        logger.notice("手动重试系统模型准备")
        try? await runPreparation(operation)
    }

    // MARK: - 复位

    /// 取消挂起的自动重试并复位状态（退后台即停，§10-2）。
    func reset() {
        lock.withLock {
            pendingRetryTask?.cancel()
            pendingRetryTask = nil
            autoRetryCount = 0
        }
    }

    // MARK: - 私有：状态发射

    /// 更新快照并向流广播。
    private func emit(_ state: EngineState) {
        status = state
        continuation.yield(state)
        logger.notice("VT 模型下载状态: \(state.displayName)")
    }

    // MARK: - 私有：自动重试策略

    /// 网络型失败时调度自动重试（最多 2 次，退避 5s → 15s）。
    private func scheduleAutoRetryIfNeeded(for error: Error) {
        guard Self.isNetworkLike(error) else { return }
        let (operation, retryIndex) = lock.withLock { () -> ((@Sendable () async throws -> Void)?, Int) in
            guard autoRetryCount < Self.backoffSeconds.count else { return (nil, autoRetryCount) }
            let index = autoRetryCount
            autoRetryCount += 1
            return (lastOperation, index)
        }
        guard let operation else {
            logger.notice("自动重试配额已用尽，转手动重试")
            return
        }
        let delay = Self.backoffSeconds[min(retryIndex, Self.backoffSeconds.count - 1)]
        logger.notice("将于 \(delay)s 后第 \(retryIndex + 1) 次自动重试")
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // 复跑准备；其内部会继续走三态发射与后续重试调度。
            try? await self.runPreparation(operation)
        }
        lock.withLock { pendingRetryTask = task }
    }

    /// 判定错误是否网络型（URLError 族），仅此类错误自动重试（§10-2）。
    private static func isNetworkLike(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }
}
