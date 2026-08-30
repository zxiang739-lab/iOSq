//
//  ModelLibraryViewModel.swift
//  VTFramePro
//
//  模型库 ViewModel：导入 / 删除 / 设为当前 / 校验失败原因展示（L2）。
//  对应 PRD §3.2 模型管理页、R-13/R-19/R-20/R-32。
//

import Foundation
import Observation
import OSLog

/// 模型库 ViewModel。
///
/// 编排：文件选择器导入 → ModelLibraryService 校验入库 →
/// 实例化 CoreMLImportEngine 注册到 EngineRegistry → 列表刷新；
/// 删除 → 反注册引擎 + 清单/沙盒移除；设为当前 → EngineRegistry.setActive。
///
/// 线程：@MainActor。
@Observable
@MainActor
final class ModelLibraryViewModel {

    // MARK: - 可观察状态

    /// 已导入模型列表（导入时间倒序）。
    private(set) var models: [ImportedModel] = []
    /// 系统 VT 引擎状态（分区头部展示，含下载三态）。
    private(set) var vtEngineState: EngineState = .checking
    /// 各能力当前生效引擎名（「当前」标记展示）。
    private(set) var activeEngineNames: [EngineCapability: String] = [:]
    /// 导入中标志（文件较大时展示进度态）。
    private(set) var isImporting = false
    /// 导入用途选择（导入弹窗绑定）。
    var importKind: EngineCapability = .frameInterpolation
    /// 校验失败原因列表（R-32 具体原因展示；非 nil 时 View 呈现）。
    var validationFailureReasons: [String]?
    /// 待呈现错误（View 弹窗）。
    var activeError: AppError?

    // MARK: - 依赖与私有

    private let dependencies: AppDependencies
    private let logger = Logger(subsystem: "com.vtframepro", category: "ui")

    // MARK: - 初始化

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - 刷新

    /// 进入页面时拉取清单与引擎状态（幂等）。
    func refresh() async {
        models = await dependencies.modelLibraryService.loadManifest()
            .sorted { $0.importedAt > $1.importedAt }
        let registry = dependencies.engineRegistry
        vtEngineState = registry.engines.first { $0.kind == .systemVT }?.state ?? .checking
        activeEngineNames = registry.activeEngine.mapValues { $0.displayName }
    }

    // MARK: - 导入（R-13/R-32）

    /// 文件选择器导入 mlpackage。
    ///
    /// 流程：沙盒拷贝 → 张量五规则校验（失败展示全部原因，拒绝入库）→
    /// 清单持久化 → 实例化引擎注册。
    func importPickedModel(from url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let descriptor = try await dependencies.modelLibraryService.importModel(
                from: url, declaredKind: importKind)
            // 实例化 CoreML 引擎并注册（§2.4：每个模型一个引擎实例）。
            let engine = CoreMLImportEngine(
                descriptor: descriptor,
                pixelBufferPool: dependencies.pixelBufferPool,
                modelURL: dependencies.modelLibraryService.sandboxURL(for: descriptor)
            )
            dependencies.engineRegistry.register(engine)
            await refresh()
            logger.notice("模型已导入并注册: \(descriptor.displayName)")
        } catch let error as AppError {
            if case .modelValidationFailed(let reasons) = error {
                // R-32：校验失败给出具体原因（不泛化弹窗）。
                validationFailureReasons = reasons
            } else {
                activeError = error.shouldPresentAlert ? error : nil
            }
        } catch {
            activeError = .ioFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - 删除（R-19）

    /// 删除模型：引擎反注册 → 清单/沙盒移除。
    func delete(modelID: UUID) async {
        do {
            let removed = try await dependencies.modelLibraryService.delete(modelID: modelID)
            dependencies.engineRegistry.unregister(engineID: removed.engineID)
            await refresh()
        } catch let error as AppError {
            activeError = error.shouldPresentAlert ? error : nil
        } catch {
            activeError = .ioFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - 设为当前（R-20）

    /// 将导入模型设为其声明能力的当前生效引擎。
    func setActive(modelID: UUID) {
        guard let descriptor = models.first(where: { $0.id == modelID }),
              let engine = dependencies.engineRegistry.engine(withID: descriptor.engineID) else { return }
        do {
            try dependencies.engineRegistry.setActive(engine, for: descriptor.declaredKind)
            Task { await refresh() }
        } catch let error as AppError {
            activeError = error.shouldPresentAlert ? error : nil
        } catch {
            activeError = .engineUnsupported(detail: error.localizedDescription)
        }
    }

    /// 将系统 VT 引擎设为某能力的当前生效引擎。
    func setVTActive(for capability: EngineCapability) {
        guard let vtEngine = dependencies.engineRegistry.engine(withID: "system-vt") else { return }
        do {
            try dependencies.engineRegistry.setActive(vtEngine, for: capability)
            Task { await refresh() }
        } catch let error as AppError {
            activeError = error.shouldPresentAlert ? error : nil
        } catch {
            activeError = .engineUnsupported(detail: error.localizedDescription)
        }
    }

    /// VT 下载失败重试（R-30）。
    func retryVTDownload() async {
        guard let vtEngine = dependencies.engineRegistry.engine(withID: "system-vt") else { return }
        try? await vtEngine.prepare(for: .frameInterpolation)
        await refresh()
    }
}
