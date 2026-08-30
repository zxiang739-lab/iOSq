//
//  AIEngine.swift
//  VTFramePro
//
//  统一引擎协议 + 配置值类型（L4 AI 引擎协议层）。
//  对应 ARCHITECTURE.md §2.1。实时与离线链路只面向本协议编程（§1.2 第 2 条）。
//

import Foundation
import CoreVideo

// MARK: - 推理配置值类型

/// 补帧配置。
struct InterpolationConfig: Sendable {
    /// 插值倍率。首版实时/离线均锁 x2（§10-1），字段为后续 x4 预留。
    var factor: Int = 2
    /// 链路档位（R-29 分档）：实时 .lowLatency（默认）/ 离线 .highQuality。
    /// 引擎据此选择低延迟 / 高质量会话配置。
    var quality: UpscaleQuality = .lowLatency

    /// 每对输入帧产出的中间帧插值相位序列（x2 → [0.5]）。
    var phases: [Float] {
        guard factor > 1 else { return [] }
        return (1..<factor).map { Float($0) / Float(factor) }
    }
}

/// 超分画质档（R-29 分档）。
enum UpscaleQuality: Sendable {
    /// 实时链路：低延迟档（VTLowLatencySuperResolutionScaler / CoreML 实时配置）。
    case lowLatency
    /// 离线链路：高质量档（VTSuperResolutionScaler / CoreML 高质量配置）。
    case highQuality
}

// MARK: - 像素缓冲跨域包装

/// `CVPixelBuffer` 的 `@unchecked Sendable` 薄包装（§8.4）。
///
/// CVPixelBuffer 是引用语义 CoreFoundation 类型，Swift 6 严格并发下不能
/// 直接跨隔离域传递。本包装仅传引用、不拷贝像素；生命周期由持有方显式管理
/// （实时链路：引擎推理完成前持有；离线链路：autoreleasepool 批次内持有）。
struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer

    init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }
}

// MARK: - 统一引擎协议

/// 双引擎统一抽象。
///
/// 实现方：
/// - `VTFrameProcessorEngine`（系统 VT 引擎，iOS 26+，isSupported 检测）；
/// - `CoreMLImportEngine`（用户导入 mlpackage，CoreML + MPS）。
///
/// 约定：
/// - 推理方法（`interpolate`/`upscale`）在实现方自己的并发域执行（非 MainActor，§8.4）；
/// - 输出 buffer 由实现方从注入的 `PixelBufferPool` 分配，调用方用毕即释放回池；
/// - `MLModel`/VT 会话对象绝不允许离开实现方（§1.2 第 3 条）。
protocol AIEngine: AnyObject, Sendable {

    /// 稳定标识（"system-vt" / "coreml-<模型UUID>"）。
    var engineID: String { get }

    /// UI 展示名。
    var displayName: String { get }

    /// 引擎种类（.systemVT / .coreMLImported）。
    var kind: EngineKind { get }

    /// 声明的能力集（VT 引擎两者皆备；CoreML 引擎由导入时声明用途决定）。
    var capabilities: Set<EngineCapability> { get }

    /// 当前状态快照。
    var state: EngineState { get }

    /// 状态流（下载进度等，供 ViewModel 订阅三态展示）。
    var stateUpdates: AsyncStream<EngineState> { get }

    /// 能力检测 / 预热。
    ///
    /// VT：isSupported 检测 + 触发系统模型下载检查；
    /// CoreML：加载并预热 MLModel（黑帧推理一次，消除首帧抖动）。
    /// 幂等，可重复调用（如下载失败重试，§10-2）。
    ///
    /// - Parameter capability: 准备用于的能力。
    /// - Throws: `AppError.engineUnsupported` / `.modelDownloadFailed` / `.inferenceFailed`。
    func prepare(for capability: EngineCapability) async throws

    /// 补帧：输入两帧 + 插值位置（0~1，x2 时为 0.5），输出中间帧。
    ///
    /// - Parameters:
    ///   - frame0: 前一帧（仅传引用，实现方不得修改像素）。
    ///   - frame1: 后一帧。
    ///   - timestep: 插值相位 ∈ (0, 1)。
    ///   - capabilityConfig: 补帧配置（首版锁 x2）。
    /// - Returns: 中间帧（池化分配，调用方负责释放）。
    /// - Throws: `AppError.inferenceFailed`。
    func interpolate(frame0: CVPixelBuffer,
                     frame1: CVPixelBuffer,
                     at timestep: Float,
                     capability capabilityConfig: InterpolationConfig) async throws -> CVPixelBuffer

    /// 超分：输入一帧，按 scale 放大输出。
    ///
    /// - Parameters:
    ///   - frame: 输入帧。
    ///   - scale: 放大倍率（离线固定 2；实时按档位）。
    ///   - qualityConfig: 画质档（实时 .lowLatency / 离线 .highQuality，R-29）。
    /// - Returns: 放大帧（池化分配，调用方负责释放）。
    /// - Throws: `AppError.inferenceFailed`。
    func upscale(_ frame: CVPixelBuffer,
                 scale: Int,
                 quality qualityConfig: UpscaleQuality) async throws -> CVPixelBuffer

    /// 释放推理资源（链路停止 / 引擎被切走时调用）。
    ///
    /// VT：endSession 释放会话；CoreML：释放 MLModel 引用。
    /// 幂等。
    func reset() async
}
