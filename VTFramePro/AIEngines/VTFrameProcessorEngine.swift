//
//  VTFrameProcessorEngine.swift
//  VTFramePro
//
//  系统 VT 引擎实现（L4 AI 引擎协议层，iOS 26+，isSupported 检测）。
//  对应 ARCHITECTURE.md §2.4 / §3.3（R-27/28/29）。
//
//  ※SDK 兜底约定（§3.3.5）：全部 VTFrameProcessor 相关符号收敛于本文件，
//  统一包裹 `#if canImport(VideoToolbox)` + `@available(iOS 26.0, *)`；
//  符号以 Xcode 26 实际头文件为准校正，不使用任何动态探测私有符号手段。
//

import Foundation
import CoreMedia
import CoreVideo
import OSLog

#if canImport(VideoToolbox)
import VideoToolbox

/// 系统 VTFrameProcessor 引擎。
///
/// 能力：补帧 + 超分双能力（§2.4）。
/// 会话分档（R-29）：
/// - 实时补帧：`VTLowLatencyFrameInterpolationConfiguration`（低延迟插值）；
/// - 离线补帧：`VTFrameRateConversionConfiguration`（高质量帧率转换）；
/// - 实时超分：`VTLowLatencySuperResolutionScalerConfiguration`（低延迟超分）；
/// - 离线超分：`VTSuperResolutionScalerConfiguration`（高质量超分）※SDK。
///
/// 线程：`@unchecked Sendable`——内部可变状态全部由 `stateLock` 保护；
/// VT 会话的创建与调用在调用方并发域执行（推理为同步阻塞/异步回调，§8.4）。
@available(iOS 26.0, *)
final class VTFrameProcessorEngine: AIEngine, @unchecked Sendable {

    // MARK: - AIEngine 标识

    let engineID: String = "system-vt"
    let displayName: String = "系统 VT 引擎"
    let kind: EngineKind = .systemVT
    let capabilities: Set<EngineCapability> = [.frameInterpolation, .superResolution]

    // MARK: - 状态

    /// 当前状态快照（锁保护）。
    private(set) var state: EngineState {
        get { stateLock.withLock { _state } }
        set { stateLock.withLock { _state = newValue } }
    }

    /// 状态流（含下载三态，桥接自 VTModelDownloadManager）。
    let stateUpdates: AsyncStream<EngineState>

    // MARK: - 依赖

    /// 输出帧池（输出 buffer 由此分配，§2.1）。
    private let pixelBufferPool: PixelBufferPool
    /// 系统模型下载三态管理（内嵌，类图 VTFrameProcessorEngine *-- VTModelDownloadManager）。
    private let downloadManager: VTModelDownloadManager

    // MARK: - 会话存储

    /// VT 会话桶：按「用途 + 输入尺寸」缓存，避免每帧重建会话。
    private struct SessionKey: Hashable {
        let purpose: Purpose
        let width: Int
        let height: Int
    }

    /// 会话用途（实时/离线 × 补帧/超分 四档）。
    private enum Purpose: Hashable {
        case realtimeInterpolation      // VTLowLatencyFrameInterpolationConfiguration
        case offlineInterpolation       // VTFrameRateConversionConfiguration
        case realtimeSuperResolution    // VTLowLatencySuperResolutionScalerConfiguration
        case offlineSuperResolution     // VTSuperResolutionScalerConfiguration ※SDK
    }

    /// 已建立的会话（值类型包装引用，字典本身锁保护）。
    private var sessions: [SessionKey: VTFrameProcessor] = [:]

    // MARK: - 私有状态

    private let stateLock = NSLock()
    private var _state: EngineState = .checking
    private let stateContinuation: AsyncStream<EngineState>.Continuation
    /// 单调帧序号（合成 PTS 用，锁保护）。
    private var frameSequence: Int64 = 0
    /// 下载状态桥接任务。
    private var bridgeTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.vtframepro", category: "engine")

    // MARK: - 初始化

    init(pixelBufferPool: PixelBufferPool, downloadManager: VTModelDownloadManager) {
        self.pixelBufferPool = pixelBufferPool
        self.downloadManager = downloadManager
        var continuation: AsyncStream<EngineState>.Continuation!
        self.stateUpdates = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation

        // 桥接下载三态：下载管理器状态即本引擎准备阶段状态。
        bridgeTask = Task { [weak self, downloadManager] in
            for await downloadState in downloadManager.statusUpdates {
                guard let self else { return }
                self.emit(downloadState)
            }
        }
    }

    deinit {
        bridgeTask?.cancel()
        stateContinuation.finish()
    }

    // MARK: - 能力检测（静态入口）

    /// 运行时能力检测（§3.3.5 兜底写法）。
    ///
    /// isSupported 为各配置类的类属性（WWDC25 公开 API）：
    /// 补帧看 `VTLowLatencyFrameInterpolationConfiguration`，
    /// 超分看 `VTLowLatencySuperResolutionScalerConfiguration`，两者皆真才算可用。
    static var runtimeSupported: Bool {
        guard #available(iOS 26.0, *) else { return false }
        // ※SDK：以 Xcode 26 实际属性名为准（文档确认为 class var isSupported）。
        return VTLowLatencyFrameInterpolationConfiguration.isSupported
            && VTLowLatencySuperResolutionScalerConfiguration.isSupported
    }

    // MARK: - AIEngine.prepare

    /// 能力检测 + 触发系统模型下载/加载检查（幂等，可重复调用以重试）。
    ///
    /// 流程：isSupported → 否：置 .unsupported 并抛错；
    /// 是：经下载管理器 `runPreparation` 建立 720p 预热会话（可能触发系统模型加载），
    /// 成功 → .ready。
    func prepare(for capability: EngineCapability) async throws {
        guard Self.runtimeSupported else {
            let reason = "VTFrameProcessor 在此设备不可用（需要 iPhone 15 Pro 及以上）"
            emit(.unsupported(reason: reason))
            throw AppError.engineUnsupported(detail: reason)
        }
        // 经下载管理器桥接三态：建立预热会话即触发系统模型加载（※SDK：
        // 若后续 SDK 提供独立下载 API，在 VTModelDownloadManager 内接入）。
        try await downloadManager.runPreparation { [weak self] in
            try await self?.warmUpSession(for: capability)
        }
    }

    // MARK: - AIEngine.interpolate

    /// 补帧：实时走低延迟插值档，离线走高质量帧率转换档（R-29）。
    func interpolate(frame0: CVPixelBuffer,
                     frame1: CVPixelBuffer,
                     at timestep: Float,
                     capability capabilityConfig: InterpolationConfig) async throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)

        // 分档选择：离线链路（.highQuality）用帧率转换配置；实时用低延迟配置。
        let isOfflineLane = capabilityConfig.quality == .highQuality
        let purpose: Purpose = isOfflineLane ? .offlineInterpolation : .realtimeInterpolation

        // 输出帧：尺寸与输入一致（补帧不改分辨率），池化分配。
        let destination = try pixelBufferPool.acquire(width: width, height: height)

        do {
            let processor = try session(for: purpose, width: width, height: height)
            let pts0 = nextTimestamp()
            let pts1 = nextTimestamp()
            // 中间帧 PTS = pts0 + timestep × (pts1 - pts0)。
            let ptsMid = CMTimeAdd(
                pts0,
                CMTimeMultiplyByFloat64(CMTimeSubtract(pts1, pts0),
                                        multiplier: Float64(timestep))
            )
            guard let sourceFrame = VTFrameProcessorFrame(buffer: frame0, presentationTimeStamp: pts0),
                  let nextFrame = VTFrameProcessorFrame(buffer: frame1, presentationTimeStamp: pts1),
                  let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: ptsMid) else {
                throw AppError.inferenceFailed(underlying: "VTFrameProcessorFrame 创建失败")
            }

            if isOfflineLane {
                // 离线高质量档：VTFrameRateConversionParameters ※SDK（签名以头文件为准）。
                guard let parameters = VTFrameRateConversionParameters(
                    sourceFrame: sourceFrame,
                    nextFrame: nextFrame,
                    opticalFlow: nil,                       // 不预算光流（离线可接受实时计算）
                    interpolationPhase: [timestep],
                    submissionMode: .sequential,            // ※SDK：枚举名以头文件为准
                    destinationFrames: [destinationFrame]
                ) else {
                    throw AppError.inferenceFailed(underlying: "VTFrameRateConversionParameters 创建失败")
                }
                try await process(processor: processor, parameters: parameters)
            } else {
                // 实时低延迟档：VTLowLatencyFrameInterpolationParameters。
                // 相位须 ∈ (0,1)；destinationFrames 数量与相位一致（头文件约束）。
                guard let parameters = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: sourceFrame,
                    previousFrame: nextFrame,
                    interpolationPhase: [timestep],
                    destinationFrames: [destinationFrame]
                ) else {
                    throw AppError.inferenceFailed(underlying: "VTLowLatencyFrameInterpolationParameters 创建失败")
                }
                try await process(processor: processor, parameters: parameters)
            }
            return destination
        } catch let error as AppError {
            throw error
        } catch {
            logger.error("VT 补帧失败: \(error.localizedDescription)")
            throw AppError.inferenceFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - AIEngine.upscale

    /// 超分：实时低延迟档 / 离线高质量档（R-29）。
    func upscale(_ frame: CVPixelBuffer,
                 scale: Int,
                 quality qualityConfig: UpscaleQuality) async throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let purpose: Purpose = qualityConfig == .highQuality
            ? .offlineSuperResolution : .realtimeSuperResolution

        // 输出帧：scale 倍尺寸。
        let destination = try pixelBufferPool.acquire(width: width * scale, height: height * scale)

        do {
            let processor = try session(for: purpose, width: width, height: height,
                                        scaleFactor: Float(scale))
            let pts = nextTimestamp()
            guard let sourceFrame = VTFrameProcessorFrame(buffer: frame, presentationTimeStamp: pts),
                  let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: pts) else {
                throw AppError.inferenceFailed(underlying: "VTFrameProcessorFrame 创建失败")
            }

            if purpose == .realtimeSuperResolution {
                // 实时低延迟超分参数（头文件确认非 failable）。
                let parameters = VTLowLatencySuperResolutionScalerParameters(
                    sourceFrame: sourceFrame,
                    destinationFrame: destinationFrame
                )
                try await process(processor: processor, parameters: parameters)
            } else {
                // 离线高质量超分参数 ※SDK（VTSuperResolutionScalerParameters，
                // 签名以 Xcode 26 头文件为准，按 sourceFrame/destinationFrame 双帧形态）。
                let parameters = VTSuperResolutionScalerParameters(
                    sourceFrame: sourceFrame,
                    destinationFrame: destinationFrame
                )
                try await process(processor: processor, parameters: parameters)
            }
            return destination
        } catch let error as AppError {
            throw error
        } catch {
            logger.error("VT 超分失败: \(error.localizedDescription)")
            throw AppError.inferenceFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - AIEngine.reset

    /// 释放全部 VT 会话 + 取消下载重试（幂等）。
    func reset() async {
        stateLock.withLock {
            for (_, processor) in sessions {
                processor.endSession()
            }
            sessions.removeAll()
        }
        downloadManager.reset()
        logger.notice("VT 引擎会话已释放")
    }

    // MARK: - 私有：状态发射

    private func emit(_ newState: EngineState) {
        state = newState
        stateContinuation.yield(newState)
        logger.notice("VT 引擎状态: \(newState.displayName)")
    }

    // MARK: - 私有：预热会话

    /// 建立 720p 预热会话（触发系统模型加载/下载，消除首帧抖动）。
    private func warmUpSession(for capability: EngineCapability) async throws {
        // 预热尺寸：实时链路 720p 上限（§3.1）。
        let width = 1280, height = 720
        switch capability {
        case .frameInterpolation:
            _ = try session(for: .realtimeInterpolation, width: width, height: height)
        case .superResolution:
            _ = try session(for: .realtimeSuperResolution, width: width, height: height, scaleFactor: 2.0)
        }
    }

    // MARK: - 私有：会话创建与缓存

    /// 取/建指定用途与尺寸的 VT 会话（锁保护缓存）。
    private func session(for purpose: Purpose,
                         width: Int,
                         height: Int,
                         scaleFactor: Float = 2.0) throws -> VTFrameProcessor {
        let key = SessionKey(purpose: purpose, width: width, height: height)
        if let cached = stateLock.withLock({ sessions[key] }) {
            return cached
        }

        let processor = VTFrameProcessor()
        switch purpose {
        case .realtimeInterpolation:
            // 实时低延迟插值：numberOfInterpolatedFrames = 1（x2 锁档）。
            guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width,
                frameHeight: height,
                numberOfInterpolatedFrames: 1
            ) else {
                throw AppError.engineUnsupported(detail: "低延迟插值配置创建失败（\(width)×\(height)）")
            }
            try startSession(processor: processor, configuration: configuration)

        case .offlineInterpolation:
            // 离线高质量帧率转换 ※SDK（qualityPrioritization/revision 枚举名以头文件为准）。
            guard let configuration = VTFrameRateConversionConfiguration(
                frameWidth: width,
                frameHeight: height,
                usePrecomputedFlow: false,
                qualityPrioritization: .quality,
                revision: .revision1
            ) else {
                throw AppError.engineUnsupported(detail: "帧率转换配置创建失败（\(width)×\(height)）")
            }
            try startSession(processor: processor, configuration: configuration)

        case .realtimeSuperResolution:
            // 实时低延迟超分：scaleFactor 须为 supportedScaleFactors 返回值（头文件约束）。
            let factor = Self.supportedScaleFactor(
                desired: scaleFactor, width: width, height: height)
            let configuration = VTLowLatencySuperResolutionScalerConfiguration(
                frameWidth: width,
                frameHeight: height,
                scaleFactor: factor
            )
            try startSession(processor: processor, configuration: configuration)

        case .offlineSuperResolution:
            // 离线高质量超分 ※SDK（VTSuperResolutionScalerConfiguration 签名以头文件为准）。
            let configuration = VTSuperResolutionScalerConfiguration(
                frameWidth: width,
                frameHeight: height,
                scaleFactor: scaleFactor
            )
            try startSession(processor: processor, configuration: configuration)
        }

        stateLock.withLock { sessions[key] = processor }
        logger.notice("VT 会话已建立: \(String(describing: purpose)) \(width)×\(height)")
        return processor
    }

    /// startSession 包装（集中 ※SDK 调用点，便于按头文件校正）。
    private func startSession(processor: VTFrameProcessor,
                              configuration: any VTFrameProcessorConfiguration) throws {
        // startSession(configuration:) —— Swift 导入名（NS_SWIFT_NAME 确认）。
        // 注意：头文件注明此方法可能耗时超过一帧（模型加载），严禁主线程调用，
        // 本引擎全部调用路径均在非 MainActor 并发域（§8.4）。
        try processor.startSession(configuration: configuration)
    }

    /// process(parameters:) 异步桥接。
    ///
    /// 头文件中同步 `processWithParameters:error:` 对 Swift 不可用，
    /// 公开路径为 completionHandler 形态，此处桥接为 async throws。
    private func process(processor: VTFrameProcessor,
                         parameters: any VTFrameProcessorParameters) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - 私有：工具

    /// 生成单调递增的合成 PTS（引擎内部会话的帧时序锚点）。
    private func nextTimestamp() -> CMTime {
        let sequence = stateLock.withLock { () -> Int64 in
            frameSequence += 1
            return frameSequence
        }
        return CMTime(value: sequence, timescale: 60)
    }

    /// 就近选择受支持的实时超分倍率（头文件：supportedScaleFactors(frameWidth:frameHeight:)）。
    private static func supportedScaleFactor(desired: Float, width: Int, height: Int) -> Float {
        // ※SDK：以 Xcode 26 实际方法名为准。
        let supported = VTLowLatencySuperResolutionScalerConfiguration
            .supportedScaleFactors(frameWidth: width, frameHeight: height)
        guard !supported.isEmpty else { return desired }
        return supported.min(by: { abs($0 - desired) < abs($1 - desired) }) ?? desired
    }
}
#endif
