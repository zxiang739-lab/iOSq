//
//  MockAIEngine.swift
//  VTFrameProTests
//
//  测试替身：满足 `AIEngine` 协议的 Mock 引擎（L4 协议层测试基座）。
//  - 供 EngineRegistry / OfflineTaskQueue 等不依赖真实 MLModel/VT 会话的测试使用；
//  - 线程：`@unchecked Sendable` + NSLock（与真实引擎同款并发模型，§8.4）。
//
//  对应规则：ARCHITECTURE.md §2.1（AIEngine 协议）、§2.3（EngineRegistry）。
//

import Foundation
import CoreVideo
import XCTest
@testable import VTFramePro

/// 可控的 Mock 引擎。
///
/// 可配置项：
/// - `capabilities`：声明能力集（默认补帧+超分，模拟 VT）。
/// - `kind`：引擎种类（默认 .systemVT；CoreML 场景设 .coreMLImported）。
/// - `state`：当前状态（可用 `setState` 在线切换）。
/// - `prepareResult`：`prepare` 抛错配置（默认成功，幂等）。
/// - 调用计数：`prepareCallCount` / `resetCallCount`。
final class MockAIEngine: AIEngine, @unchecked Sendable {

    // MARK: - AIEngine 标识（可配置）

    let engineID: String
    let displayName: String
    let kind: EngineKind
    let capabilities: Set<EngineCapability>

    // MARK: - 状态流

    let stateUpdates: AsyncStream<EngineState>
    private let stateContinuation: AsyncStream<EngineState>.Continuation

    // MARK: - 锁保护状态

    private let lock = NSLock()
    private var _state: EngineState
    private var _prepareResult: Result<Void, AppError> = .success(())
    private var _prepareCallCount = 0
    private var _resetCallCount = 0

    // MARK: - 初始化

    /// - Parameters:
    ///   - engineID: 稳定标识（默认 "mock-<递增>"，可显式传 "system-vt" 等）。
    ///   - displayName: 展示名（默认取 engineID）。
    ///   - kind: 引擎种类（默认 .systemVT）。
    ///   - capabilities: 能力集（默认补帧+超分）。
    ///   - state: 初始状态（默认 .ready）。
    init(engineID: String = UUID().uuidString,
         displayName: String? = nil,
         kind: EngineKind = .systemVT,
         capabilities: Set<EngineCapability> = [.frameInterpolation, .superResolution],
         state: EngineState = .ready) {
        self.engineID = engineID
        self.displayName = displayName ?? engineID
        self.kind = kind
        self.capabilities = capabilities
        self._state = state
        var continuation: AsyncStream<EngineState>.Continuation!
        self.stateUpdates = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
    }

    // MARK: - AIEngine

    var state: EngineState {
        lock.withLock { _state }
    }

    func prepare(for capability: EngineCapability) async throws {
        lock.withLock { _prepareCallCount += 1 }
        let result = lock.withLock { _prepareResult }
        switch result {
        case .success:
            break
        case .failure(let error):
            throw error
        }
    }

    func interpolate(frame0: CVPixelBuffer,
                     frame1: CVPixelBuffer,
                     at timestep: Float,
                     capability capabilityConfig: InterpolationConfig) async throws -> CVPixelBuffer {
        // Mock 不执行推理；仅用于注册表/队列逻辑测试，绝不走到此分支。
        throw AppError.inferenceFailed(underlying: "MockAIEngine 不执行真实推理")
    }

    func upscale(_ frame: CVPixelBuffer,
                 scale: Int,
                 quality qualityConfig: UpscaleQuality) async throws -> CVPixelBuffer {
        throw AppError.inferenceFailed(underlying: "MockAIEngine 不执行真实推理")
    }

    func reset() async {
        lock.withLock { _resetCallCount += 1 }
    }

    // MARK: - 测试控制

    /// 在线设置状态快照（同步写入，模拟引擎状态流之外的手工控制）。
    func setState(_ newState: EngineState) {
        lock.withLock { _state = newState }
        stateContinuation.yield(newState)
    }

    /// 配置 prepare 失败（校验 setActive 之外的抛错路径）。
    func setPrepareFailure(_ error: AppError?) {
        lock.withLock {
            _prepareResult = error.map { .failure($0) } ?? .success(())
        }
    }

    /// 记录到某能力的 prepare 调用次数。
    var prepareCallCount: Int { lock.withLock { _prepareCallCount } }
    /// reset 调用次数。
    var resetCallCount: Int { lock.withLock { _resetCallCount } }
}

// MARK: - 测试异步轮询工具

/// 轮询等待条件成立（带超时），避免脆弱的固定 sleep。
///
/// - Parameters:
///   - timeout: 超时秒数（默认 5s，覆盖慢 CI）。
///   - interval: 轮询间隔（默认 10ms）。
///   - condition: 异步条件闭包（@MainActor，可 await actor 方法）。
@MainActor
func waitUntil(timeout: TimeInterval = 5,
               interval: TimeInterval = 0.01,
               _ condition: @escaping @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    return await condition()
}