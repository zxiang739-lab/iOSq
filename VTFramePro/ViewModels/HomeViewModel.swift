//
//  HomeViewModel.swift
//  VTFramePro
//
//  首页 ViewModel：5 模式入口状态、当前引擎展示、置灰决策（L2）。
//  对应 PRD §3.2 主界面与 R-28/R-31。
//

import Foundation
import Observation

/// 首页 ViewModel。
///
/// 职责：把 5 种模式映射为入口卡片状态——
/// 每种模式按其 `requiredCapabilities` 经 EngineRegistry 降级决策判定可用性，
/// 无可用引擎时置灰并给出原因（R-31）；VT 不可用时展示降级横幅（§2.3）。
@Observable
@MainActor
final class HomeViewModel {

    // MARK: - 入口卡片模型

    /// 单个模式入口的 UI 状态。
    struct ModeEntry: Identifiable, Equatable {
        let mode: ProcessingMode
        /// 是否可点击进入。
        let isEnabled: Bool
        /// 置灰原因（不可用时非 nil，友好文案）。
        let disabledReason: String?
        /// 当前将为该模式服务的引擎名。
        let engineName: String?

        var id: String { mode.id }
    }

    // MARK: - 可观察状态

    /// 5 模式入口卡片（按 ProcessingMode 全量顺序）。
    private(set) var entries: [ModeEntry] = []
    /// 降级横幅文案（引擎自动切换时非 nil，§2.3）。
    private(set) var fallbackNotice: String?
    /// 系统 VT 引擎状态（顶部状态条展示，含下载三态）。
    private(set) var vtEngineState: EngineState = .checking

    // MARK: - 依赖

    /// DI 容器（内部包级可见：首页导航实时页时透传构造 RealtimeViewModel）。
    let dependencies: AppDependencies

    // MARK: - 初始化

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - 刷新（进入页面 / 回前台时调用）

    /// 重算全部入口状态（幂等）。
    func refresh() {
        let registry = dependencies.engineRegistry
        fallbackNotice = registry.fallbackNotice
        vtEngineState = registry.engines.first { $0.kind == .systemVT }?.state ?? .checking

        entries = ProcessingMode.allCases.map { mode in
            // 多能力模式（串联）须每种能力都有可用引擎。
            let unavailableCapabilities = mode.requiredCapabilities.filter {
                registry.resolveUsableEngine(for: $0) == nil
            }
            let isEnabled = unavailableCapabilities.isEmpty
            let disabledReason: String? = isEnabled ? nil : unavailableCapabilities
                .map { registry.unavailableReason(for: $0) }
                .joined(separator: "；")
            // 展示该模式首要能力的生效引擎名。
            let engineName = mode.requiredCapabilities.first
                .flatMap { registry.activeEngine[$0] }?.displayName
            return ModeEntry(
                mode: mode,
                isEnabled: isEnabled,
                disabledReason: disabledReason,
                engineName: engineName
            )
        }
        // 降级决策可能更新横幅（resolveUsableEngine 副作用）。
        fallbackNotice = registry.fallbackNotice
    }
}
