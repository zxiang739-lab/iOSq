//
//  RealtimeViewModel.swift
//  VTFramePro
//
//  实时链路 ViewModel：启停 / 引擎与档位切换 / 指标订阅 / 下载三态展示（L2）。
//  对应 PRD §3.2 实时预览页、R-10 状态面板、R-30 下载三态、R-31 降级。
//

import Foundation
import CoreVideo
import Observation
import OSLog

/// 实时预览 ViewModel。
///
/// 编排（时序见 ARCHITECTURE.md §5.2）：
/// startTapped → 权限 → resolveUsableEngine → engine.prepare → camera.start →
/// pipeline.start → 订阅 previewFrames / metrics / engine.stateUpdates 三流。
///
/// 线程：@MainActor（UI 状态变更唯一入口，§8.4）。
@Observable
@MainActor
final class RealtimeViewModel {

    // MARK: - 可观察状态

    /// 当前业务模式（实时三种之一）。
    let mode: ProcessingMode
    /// 最新预览帧（Metal 纹理直渲数据源，零拷贝上屏）。
    private(set) var previewFrame: CVPixelBuffer?
    /// 最新性能指标（500ms 刷新）。
    private(set) var metrics: PerformanceMetrics = .zero
    /// 当前引擎状态（含 VT 下载三态，驱动三态 UI）。
    private(set) var engineState: EngineState = .checking
    /// 链路是否运行中。
    private(set) var isRunning = false
    /// 是否正在启动（防重复点击）。
    private(set) var isStarting = false
    /// 当前生效引擎标识（EnginePicker 选中态）。
    private(set) var activeEngineID: String?
    /// 当前画质档位（串联模式「性能」档自动关超分级）。
    private(set) var qualityTier: RealtimeQualityTier
    /// 待呈现错误（View 弹窗；nil 无错误）。
    var activeError: AppError?
    /// 摄像头权限状态（未授权时 View 展示 PermissionGuideView）。
    private(set) var cameraPermission: PermissionStatus = .notDetermined

    // MARK: - 依赖与私有

    private let dependencies: AppDependencies
    private var previewTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var engineStateTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.vtframepro", category: "ui")

    // MARK: - 初始化

    init(mode: ProcessingMode, dependencies: AppDependencies) {
        self.mode = mode
        self.dependencies = dependencies
        self.qualityTier = dependencies.settings.realtimeQualityTier
    }

    // MARK: - 启动

    /// 「启动」按钮：权限 → 引擎解析/预热 → 采集 → 流水线 → 三流订阅。
    func startTapped() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        do {
            // ① 摄像头权限（未授权走 PermissionGuideView，不弹错误窗）。
            cameraPermission = await dependencies.permissionService.request(.camera)
            guard cameraPermission.isGranted else { return }

            // ② 引擎解析（串联模式要求单引擎覆盖全部能力，R-31 降级决策兜底）。
            let engine = try resolveEngine()
            activeEngineID = engine.engineID

            // ③ 引擎预热（VT：isSupported + 下载检查；CoreML：加载 + 黑帧预热）。
            //    下载三态经 stateUpdates 订阅先行挂上，prepare 期间 UI 即见进度。
            let capability = mode.requiredCapabilities.first ?? .frameInterpolation
            subscribeEngineState(engine)
            try await engine.prepare(for: capability)

            // ④ 采集启动（720p30）。
            try await dependencies.cameraCaptureService.start()

            // ⑤ 流水线启动（推理门闩/丢帧/DisplayLink 输出）。
            try await dependencies.realtimePipelineService.start(
                mode: mode,
                engine: engine,
                input: dependencies.cameraCaptureService.sampleBuffers,
                qualityTier: qualityTier
            )
            isRunning = true

            // ⑥ 订阅预览帧流与指标流。
            subscribePreviewFrames()
            subscribeMetrics()
            logger.notice("实时链路已启动: \(self.mode.displayName)")
        } catch let error as AppError {
            activeError = error.shouldPresentAlert ? error : nil
        } catch {
            activeError = .ioFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - 停止

    /// 「停止」按钮：流水线 → 采集 → 引擎释放（§5.2 时序）。
    func stopTapped() {
        guard isRunning else { return }
        isRunning = false
        previewTask?.cancel()
        metricsTask?.cancel()
        let engine = activeEngineID.flatMap {
            dependencies.engineRegistry.engine(withID: $0)
        }
        Task { @MainActor in
            await dependencies.realtimePipelineService.stop()
            await dependencies.cameraCaptureService.stop()
            await engine?.reset()
            previewFrame = nil
            metrics = .zero
            logger.notice("实时链路已停止")
        }
    }

    // MARK: - 引擎切换（R-20 热切换）

    /// 选择引擎（EnginePicker 回调）。
    ///
    /// 运行中：经流水线热切换（旧 reset → 新 prepare，预热期原帧直通）；
    /// 未运行：仅更新注册表生效位。
    func selectEngine(id engineID: String) async {
        guard let engine = dependencies.engineRegistry.engine(withID: engineID) else { return }
        // 串联模式：目标引擎须覆盖全部所需能力（单引擎串联约定）。
        guard engine.capabilities.isSuperset(of: mode.requiredCapabilities) else {
            activeError = .engineUnsupported(
                detail: "\(engine.displayName) 不具备\(mode.displayName)所需的全部能力")
            return
        }
        let capability = mode.requiredCapabilities.first ?? .frameInterpolation
        do {
            try dependencies.engineRegistry.setActive(engine, for: capability)
            activeEngineID = engineID
            subscribeEngineState(engine)
            if isRunning {
                await dependencies.realtimePipelineService.switchEngine(to: engine)
            }
        } catch let error as AppError {
            activeError = error.shouldPresentAlert ? error : nil
        } catch {
            activeError = .ioFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - 画质档位（R-21/R-29）

    /// 切换画质档位（运行中即时生效于下一推理周期）。
    func selectQualityTier(_ tier: RealtimeQualityTier) {
        qualityTier = tier
        // 持久化为默认参数（设置页同源）。
        var settings = dependencies.settings
        settings.realtimeQualityTier = tier
        settings.save()
    }

    // MARK: - 下载重试（R-30 / §10-2）

    /// 「重试」按钮：VT 下载失败后手动重试（重跑 prepare 即重试，幂等）。
    func retryDownloadTapped() async {
        guard let engine = activeEngineID.flatMap({
            dependencies.engineRegistry.engine(withID: $0)
        }), let capability = mode.requiredCapabilities.first else { return }
        do {
            try await engine.prepare(for: capability)
        } catch let error as AppError {
            activeError = error.shouldPresentAlert ? error : nil
        } catch {
            activeError = .modelDownloadFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - 私有：引擎解析

    /// 解析当前模式的可用引擎。
    ///
    /// 串联模式：单引擎须声明覆盖全部所需能力（流水线单引擎串联约定，§3.1-①）；
    /// 单能力模式：注册表降级决策（R-31）。
    private func resolveEngine() throws -> any AIEngine {
        let required = mode.requiredCapabilities
        // 优先：用户设定且声明超集的就绪引擎 / 任一声明超集的就绪引擎。
        if let superset = dependencies.engineRegistry.engines.first(where: {
            $0.capabilities.isSuperset(of: required) && $0.state.isUsable
        }) {
            return superset
        }
        // 兜底：单能力降级决策。
        if let capability = required.first,
           let resolved = dependencies.engineRegistry.resolveUsableEngine(for: capability),
           resolved.capabilities.isSuperset(of: required) {
            return resolved
        }
        throw AppError.noUsableEngine(capability: required.first ?? .frameInterpolation)
    }

    // MARK: - 私有：三流订阅

    /// 预览帧流 → previewFrame（DisplayLink 节拍天然节流，直接赋值）。
    private func subscribePreviewFrames() {
        previewTask?.cancel()
        guard let stream = dependencies.realtimePipelineService.previewFrames else { return }
        previewTask = Task { @MainActor [weak self] in
            for await frame in stream {
                guard !Task.isCancelled else { return }
                self?.previewFrame = frame
            }
        }
    }

    /// 指标流 → metrics（500ms 快照）。
    private func subscribeMetrics() {
        metricsTask?.cancel()
        let stream = dependencies.metricsCollector.metrics
        metricsTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                self?.metrics = snapshot
            }
        }
    }

    /// 引擎状态流 → engineState（VT 下载三态 UI 数据源）。
    private func subscribeEngineState(_ engine: any AIEngine) {
        engineStateTask?.cancel()
        engineState = engine.state
        let stream = engine.stateUpdates
        engineStateTask = Task { @MainActor [weak self] in
            for await state in stream {
                guard !Task.isCancelled else { return }
                self?.engineState = state
            }
        }
    }
}
