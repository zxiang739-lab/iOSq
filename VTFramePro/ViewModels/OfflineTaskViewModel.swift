//
//  OfflineTaskViewModel.swift
//  VTFramePro
//
//  离线任务 ViewModel：选片 / 建任务 / 排队 / 取消 / 进度订阅（L2）。
//  对应 PRD §3.2 离线任务页与 R-14（严格串行队列）。
//

import Foundation
import Observation
import OSLog

/// 离线任务 ViewModel。
///
/// 编排（时序见 ARCHITECTURE.md §5.3）：
/// importVideo → 源文件拷入沙盒临时区 → 引擎解析（R-31 降级）→
/// OfflineTaskQueue.enqueue → taskUpdates 流驱动列表刷新。
///
/// 线程：@MainActor。
@Observable
@MainActor
final class OfflineTaskViewModel {

    // MARK: - 可观察状态

    /// 全部任务（含终态历史，新任务在前）。
    private(set) var tasks: [OfflineTask] = []
    /// 新建任务选定的引擎标识（EnginePicker 绑定；nil 跟随注册表降级决策）。
    var selectedEngineID: String?
    /// 待呈现错误（View 弹窗）。
    var activeError: AppError?
    /// 完成后待回放的输出 URL（View 导航到 GlassPlayerView）。
    var playbackURL: URL?

    // MARK: - 依赖与私有

    private let dependencies: AppDependencies
    private var updatesTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.vtframepro", category: "ui")

    // MARK: - 初始化

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        subscribeTaskUpdates()
    }

    // MARK: - 建任务

    /// 选片完成：拷贝源文件 → 解析引擎 → 入队。
    ///
    /// - Parameters:
    ///   - sourceURL: 文件选择器返回的视频 URL。
    ///   - mode: 离线模式（.offlineInterpolation / .offlineSuperResolution）。
    func importVideo(from sourceURL: URL, mode: ProcessingMode) async {
        guard !mode.isRealtime else { return }
        do {
            // ① 源文件拷入沙盒临时区（安全域 URL 生命周期只覆盖本次调用，
            //    串行队列执行时原 URL 可能已失效，必须落盘，§3.2）。
            let stagedURL = try stage(sourceURL: sourceURL)

            // ② 引擎解析：用户选定优先，否则注册表降级决策（R-31）。
            let capability: EngineCapability = mode == .offlineInterpolation
                ? .frameInterpolation : .superResolution
            let engine: any AIEngine
            if let selectedEngineID,
               let selected = dependencies.engineRegistry.engine(withID: selectedEngineID),
               selected.state.isUsable {
                engine = selected
            } else if let resolved = dependencies.engineRegistry.resolveUsableEngine(for: capability) {
                engine = resolved
            } else {
                throw AppError.noUsableEngine(capability: capability)
            }

            // ③ 入队（严格串行）。
            let task = OfflineTask(
                mode: mode,
                sourceVideoURL: stagedURL,
                engineID: engine.engineID
            )
            await dependencies.offlineTaskQueue.enqueue(task)
            logger.notice("离线任务已创建: \(task.sourceFileName) [\(mode.displayName)]")
        } catch let error as AppError {
            activeError = error.shouldPresentAlert ? error : nil
        } catch {
            activeError = .ioFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - 取消

    /// 取消任务（排队/执行中均可，取消不弹错误窗，§8.2）。
    func cancel(taskID: UUID) async {
        await dependencies.offlineTaskQueue.cancel(taskID: taskID)
    }

    // MARK: - 完成回放

    /// 已完成任务点击：进入播放器预览（输出文件保留至启动清扫，§9.3）。
    func openPlayback(for task: OfflineTask) {
        guard case .completed(let outputURL) = task.status else { return }
        playbackURL = outputURL
    }

    /// 引擎展示名（任务列表副标题）。
    func engineName(for task: OfflineTask) -> String {
        dependencies.engineRegistry.engine(withID: task.engineID)?.displayName ?? task.engineID
    }

    // MARK: - 私有：任务流订阅

    /// 订阅队列任务流（入队/进度/终态驱动列表刷新）。
    private func subscribeTaskUpdates() {
        updatesTask?.cancel()
        let queue = dependencies.offlineTaskQueue
        updatesTask = Task { @MainActor [weak self] in
            // 先拉全量快照（覆盖订阅前已存在的任务）。
            self?.tasks = await queue.currentTasks().sorted { $0.createdAt > $1.createdAt }
            for await updated in queue.taskUpdates {
                guard !Task.isCancelled, let self else { return }
                if let index = self.tasks.firstIndex(where: { $0.id == updated.id }) {
                    self.tasks[index] = updated
                } else {
                    self.tasks.insert(updated, at: 0)
                }
            }
        }
    }

    // MARK: - 私有：源文件落盘

    /// 安全域源文件拷入临时区（队列异步执行时仍可访问）。
    private func stage(sourceURL: URL) throws -> URL {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "vtframepro", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "src-\(UUID().uuidString).mov")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }
}
