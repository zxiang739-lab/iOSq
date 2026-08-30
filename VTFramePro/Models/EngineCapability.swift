//
//  EngineCapability.swift
//  VTFramePro
//
//  引擎能力 / 种类 / 状态枚举（L5 Model 层，纯值类型，无框架依赖）。
//  对应 ARCHITECTURE.md §2.1。
//

import Foundation

// MARK: - 引擎能力

/// 引擎可声明的 AI 能力集合。
/// 补帧（帧插值）与超分（空间放大）是首版全部两类能力，
/// 5 种业务模式（见 `ProcessingMode`）均映射到这两类能力的组合。
enum EngineCapability: String, CaseIterable, Sendable, Codable {
    /// 补帧：在两帧之间合成中间帧（首版实时/离线均锁 x2）。
    case frameInterpolation
    /// 超分：将帧按整数倍放大（离线固定 x2，实时按档位）。
    case superResolution

    /// 面向用户的能力名称。
    var displayName: String {
        switch self {
        case .frameInterpolation: return "补帧"
        case .superResolution: return "超分"
        }
    }
}

// MARK: - 引擎种类

/// 引擎来源种类。
enum EngineKind: String, Sendable, Codable {
    /// 系统 VideoToolbox VTFrameProcessor 引擎（iOS 26+，能力需运行时检测）。
    case systemVT
    /// 用户导入的 CoreML mlpackage 引擎（CoreML + MPS 实现）。
    case coreMLImported

    var displayName: String {
        switch self {
        case .systemVT: return "系统 VT 引擎"
        case .coreMLImported: return "导入模型"
        }
    }
}

// MARK: - 引擎状态

/// 引擎运行状态快照。
///
/// 状态机流转：
/// `checking` → `ready` / `unsupported` / `modelNotInstalled`
/// VT 引擎另有下载三态：`modelDownloading` ⇄ `downloadFailed`（可重试）→ `ready`。
///
/// - Note: `Equatable` 用于 ViewModel 状态比对；关联值带标签（§8.1）。
enum EngineState: Equatable, Sendable {
    /// 启动时能力检测中。
    case checking
    /// 可用。
    case ready
    /// 硬件/系统不支持（入口置灰，附原因文案）。
    case unsupported(reason: String)
    /// CoreML 引擎：无已导入模型（仅用于占位展示）。
    case modelNotInstalled
    /// VT 引擎：系统模型下载中。progress ∈ [0, 1]。
    case modelDownloading(progress: Double)
    /// VT 引擎：下载失败（可重试），附失败描述。
    case downloadFailed(message: String)

    /// 当前是否可直接用于推理。
    var isUsable: Bool {
        self == .ready
    }

    /// 面向用户的状态短文案（状态面板 / 置灰提示复用）。
    var displayName: String {
        switch self {
        case .checking: return "检测中…"
        case .ready: return "就绪"
        case .unsupported(let reason): return "不支持：\(reason)"
        case .modelNotInstalled: return "未导入模型"
        case .modelDownloading(let progress):
            return String(format: "模型下载中 %.0f%%", progress * 100)
        case .downloadFailed(let message): return "下载失败：\(message)"
        }
    }
}
