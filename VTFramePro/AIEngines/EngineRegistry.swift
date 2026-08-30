//
//  EngineRegistry.swift
//  VTFramePro
//
//  引擎注册 / 能力查询 / 切换 / 降级决策（L4 AI 引擎协议层）。
//  对应 ARCHITECTURE.md §2.3（R-20 切换、R-31 降级）。
//

import Foundation
import Observation
import OSLog

/// 引擎注册表。
///
/// 职责：
/// - 维护全部已注册引擎（1 个 VTFrameProcessorEngine + N 个 CoreMLImportEngine）；
/// - 记录每种能力的当前生效引擎（R-20 处理前可选）；
/// - 提供降级决策（R-31）：用户指定引擎不可用 → 自动回落第一个 ready 引擎 → 均不可用返回 nil；
/// - 启动 / 回前台时重跑能力检测（`refreshStates`）。
///
/// 线程：`@MainActor`（对外 API 全部主线程，§8.4）；内部只持有引擎引用，
/// 引擎自身的推理并发域不受此限。
@Observable
@MainActor
final class EngineRegistry {

    // MARK: - 可观察状态

    /// 全部已注册引擎。
    private(set) var engines: [any AIEngine] = []

    /// 当前生效引擎（每种能力各记录一个）。
    private(set) var activeEngine: [EngineCapability: any AIEngine] = [:]

    /// 最近一次降级提示文案（非 nil 时 UI 展示横幅，§2.3 降级策略）。
    private(set) var fallbackNotice: String?

    // MARK: - 私有

    private let logger = Logger(subsystem: "com.vtframepro", category: "engine")

    // MARK: - 初始化

    /// 无参构造（全部状态有默认值，允许在非隔离上下文创建实例后交 MainActor 使用）。
    nonisolated init() {}

    // MARK: - 注册 / 反注册

    /// 注册引擎（启动时注册 VT；导入模型后注册 CoreML）。
    /// 重复注册同 engineID 时先移除旧实例（幂等）。
    func register(_ engine: any AIEngine) {
        engines.removeAll { $0.engineID == engine.engineID }
        engines.append(engine)
        logger.notice("引擎已注册: \(engine.engineID) (\(engine.displayName))")

        // 若该能力尚无生效引擎且新引擎声明了此能力，自动设为默认（首个可用引擎优先）。
        for capability in engine.capabilities where activeEngine[capability] == nil {
            activeEngine[capability] = engine
        }
    }

    /// 反注册（删除模型时调用）。
    /// - Parameter engineID: 目标引擎标识。
    func unregister(engineID: String) {
        engines.removeAll { $0.engineID == engineID }
        // 摘除其占据的生效位，降级决策会在下次 resolve 时自动回落。
        for (capability, engine) in activeEngine where engine.engineID == engineID {
            activeEngine.removeValue(forKey: capability)
        }
        logger.notice("引擎已反注册: \(engineID)")
    }

    // MARK: - 查询

    /// 按标识取引擎（离线队列解析等场景）。
    /// - Parameter engineID: 引擎标识。
    /// - Returns: 命中引擎，未注册返回 nil。
    func engine(withID engineID: String) -> (any AIEngine)? {
        engines.first { $0.engineID == engineID }
    }

    // MARK: - 能力检测

    /// 重跑全部引擎能力检测（App 启动一次 + 回前台重检，§3.3-3）。
    ///
    /// 并发触发各引擎 `prepare` 的检测路径；单个失败不影响其余。
    func refreshStates() async {
        logger.notice("开始引擎能力重检，共 \(self.engines.count) 个引擎")
        await withTaskGroup(of: Void.self) { group in
            for engine in engines {
                group.addTask {
                    // VT：isSupported 重检 + 系统模型下载状态桥接；
                    // CoreML：加载 + 预热常驻（§9.2-5 模型常驻策略——
                    // 导入模型规模小且数量少，启动期一次预热换取链路零首帧抖动）。
                    // 单引擎失败不影响其余（try? 吞错，状态由各引擎自身 state 表达）。
                    for capability in engine.capabilities {
                        try? await engine.prepare(for: capability)
                    }
                }
            }
        }
    }

    // MARK: - 切换

    /// 设定某能力的生效引擎（R-20）。
    ///
    /// - Parameters:
    ///   - engine: 目标引擎。
    ///   - capability: 能力。
    /// - Throws: `AppError.engineUnsupported`（引擎未声明该能力时）。
    func setActive(_ engine: any AIEngine,
                   for capability: EngineCapability) throws {
        guard engine.capabilities.contains(capability) else {
            throw AppError.engineUnsupported(
                detail: "\(engine.displayName) 不支持\(capability.displayName)"
            )
        }
        activeEngine[capability] = engine
        fallbackNotice = nil
        logger.notice("生效引擎切换: \(capability.displayName) → \(engine.displayName)")
    }

    // MARK: - 降级决策（R-31）

    /// 解析某能力的可用引擎。
    ///
    /// 决策顺序（§2.3）：
    /// 1. 用户指定的 active 引擎且 `state.isUsable` → 用之；
    /// 2. 否则自动切到第一个 ready 且声明该能力的引擎（UI 经 `fallbackNotice` 横幅告知）；
    /// 3. 均不可用 → 返回 nil，ViewModel 禁用入口并展示原因。
    ///
    /// - Parameter capability: 目标能力。
    /// - Returns: 可用引擎；无可用返回 nil。
    func resolveUsableEngine(for capability: EngineCapability) -> (any AIEngine)? {
        // ① 用户指定的 active 引擎可用。
        if let active = activeEngine[capability], active.state.isUsable {
            fallbackNotice = nil
            return active
        }

        // ② 自动回落：优先 VT，其后按注册序第一个 ready 引擎。
        let candidates = engines
            .filter { $0.capabilities.contains(capability) && $0.state.isUsable }
        let vtCandidates = candidates.filter { $0.kind == .systemVT }
        let coreMLCandidates = candidates.filter { $0.kind != .systemVT }
        if let fallback = (vtCandidates + coreMLCandidates).first {
            let previousName = activeEngine[capability]?.displayName
            activeEngine[capability] = fallback
            if let previousName, previousName != fallback.displayName {
                fallbackNotice = "\(previousName)不可用，已切换至「\(fallback.displayName)」"
                logger.notice("引擎降级: \(capability.displayName) → \(fallback.displayName)")
            }
            return fallback
        }

        // ③ 均不可用。
        logger.notice("无可用引擎: \(capability.displayName)")
        return nil
    }

    // MARK: - 辅助查询

    /// 某能力是否存在任何声明支持的引擎（不论状态，用于 UI 入口是否存在）。
    func hasEngine(declaring capability: EngineCapability) -> Bool {
        engines.contains { $0.capabilities.contains(capability) }
    }

    /// 某模式的不可用原因文案（全部引擎均不可用时给 UI 的置灰理由）。
    func unavailableReason(for capability: EngineCapability) -> String {
        let declaring = engines.filter { $0.capabilities.contains(capability) }
        guard !declaring.isEmpty else {
            return "设备不支持系统引擎，且未导入自定义模型"
        }
        // 聚合各引擎状态原因。
        let reasons = declaring.map { "\($0.displayName)：\($0.state.displayName)" }
        return reasons.joined(separator: "；")
    }
}
