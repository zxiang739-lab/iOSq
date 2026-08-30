//
//  AppDependencies.swift
//  VTFramePro
//
//  DI 容器：全部 Service / Engine 单例构造与暴露。
//  对应 ARCHITECTURE.md §1.2 第 4 条（依赖注入）。
//

import Foundation
import Observation

/// App 级依赖注入容器。
///
/// 职责：
/// - 以构造器注入方式组装 L3 服务、L4 引擎注册表与 L5 配置；
/// - 生命周期与 App 一致（`@State` 持有于 `VTFrameProApp`）；
/// - `bootstrap()` 完成需异步执行的启动工作：加载模型清单、注册导入引擎、
///   触发首次引擎能力检测（isSupported / 下载状态）。
///
/// 线程：整体 `@MainActor`（init 除外，见下）。服务/引擎内部各自的并发域不受此限制。
@Observable
@MainActor
final class AppDependencies {

    // MARK: - L5 配置

    /// 处理参数（每次读取最新持久化值，UserDefaults 为唯一事实源）。
    var settings: ProcessingSettings {
        ProcessingSettings.load()
    }

    // MARK: - L3 服务

    /// 权限查询与申请。
    let permissionService: PermissionService
    /// CVPixelBuffer 池化复用。
    let pixelBufferPool: PixelBufferPool
    /// 摄像头 720p30 采集。
    let cameraCaptureService: CameraCaptureService
    /// 实时帧流调度（推理门闩/丢帧/DisplayLink 输出）。
    let realtimePipelineService: RealtimePipelineService
    /// 指标采集（FPS/延迟/硬件占用，500ms 汇总）。
    let metricsCollector: MetricsCollector
    /// 离线处理主流程（AVAssetReader/Writer + 分批防 OOM）。
    let offlineProcessingService: OfflineProcessingService
    /// 严格串行任务队列（actor）。
    let offlineTaskQueue: OfflineTaskQueue
    /// 照片库保存。
    let photoLibraryService: PhotoLibraryService
    /// 模型库（导入/校验/沙盒持久化/清单管理）。
    let modelLibraryService: ModelLibraryService

    // MARK: - L4 引擎

    /// 系统 VT 模型下载三态管理。
    let vtModelDownloadManager: VTModelDownloadManager
    /// 引擎注册表（注册/切换/降级决策）。
    let engineRegistry: EngineRegistry

    // MARK: - 构造

    /// 同步构造全部单例。
    ///
    /// `nonisolated`：`VTFrameProApp` 的 `@State` 属性初始化在非隔离上下文执行；
    /// 全部成员为 Sendable 服务或自带非隔离构造，实例创建后交由 MainActor 使用。
    ///
    /// - Note: 引擎的注册（含清单中导入模型的引擎实例化）在 `bootstrap()` 中异步完成，
    ///   避免在 App 属性初始化路径上做文件 IO 与能力检测。
    nonisolated init() {
        let permissionService = PermissionService()
        let pixelBufferPool = PixelBufferPool()
        let metricsCollector = MetricsCollector()
        let vtModelDownloadManager = VTModelDownloadManager()
        let engineRegistry = EngineRegistry()
        let modelLibraryService = ModelLibraryService()
        let photoLibraryService = PhotoLibraryService(permissionService: permissionService)

        let offlineProcessingService = OfflineProcessingService(
            pixelBufferPool: pixelBufferPool,
            photoLibraryService: photoLibraryService
        )

        self.permissionService = permissionService
        self.pixelBufferPool = pixelBufferPool
        self.metricsCollector = metricsCollector
        self.vtModelDownloadManager = vtModelDownloadManager
        self.engineRegistry = engineRegistry
        self.modelLibraryService = modelLibraryService
        self.photoLibraryService = photoLibraryService
        self.offlineProcessingService = offlineProcessingService
        self.cameraCaptureService = CameraCaptureService(permissionService: permissionService)
        self.realtimePipelineService = RealtimePipelineService(
            pixelBufferPool: pixelBufferPool,
            metricsCollector: metricsCollector
        )
        self.offlineTaskQueue = OfflineTaskQueue(
            // 以局部常量注入：init 完成前禁止读 self 属性（Swift 确定初始化规则）。
            processingService: offlineProcessingService,
            engineResolver: { [weak engineRegistry] engineID in
                // 引擎解析闭包：离线队列（actor 域）→ 注册表（MainActor 域）跨界查询。
                // 返回协议类型，队列不感知具体引擎实现（§1.2 第 2 条）。
                guard let engineRegistry else { return nil }
                return await engineRegistry.engine(withID: engineID)
            }
        )
    }

    // MARK: - 启动引导

    /// 异步启动引导（App `.task` 中调用，幂等）。
    ///
    /// 步骤：
    /// 1. 注册系统 VT 引擎（`system-vt`，恒定注册，能力由 state 表达）；
    /// 2. 加载导入模型清单，为每个模型实例化 CoreML 引擎并注册；
    /// 3. 触发首次能力检测（isSupported + VT 下载状态检查）。
    func bootstrap() async {
        // 1. 系统 VT 引擎：无论是否支持都注册，状态（unsupported/downloading/ready）
        //    由 refreshStates 驱动，UI 据此置灰或展示三态。
        let vtEngine = VTFrameProcessorEngine(
            pixelBufferPool: pixelBufferPool,
            downloadManager: vtModelDownloadManager
        )
        engineRegistry.register(vtEngine)

        // 2. 已导入模型 → CoreML 引擎。
        let importedModels = await modelLibraryService.loadManifest()
        for descriptor in importedModels {
            let engine = CoreMLImportEngine(
                descriptor: descriptor,
                pixelBufferPool: pixelBufferPool,
                modelURL: modelLibraryService.sandboxURL(for: descriptor)
            )
            engineRegistry.register(engine)
        }

        // 3. 首次能力检测（启动时机：App 启动一次，§3.3-3）。
        await engineRegistry.refreshStates()
    }
}
