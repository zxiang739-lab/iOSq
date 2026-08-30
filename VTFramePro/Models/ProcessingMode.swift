//
//  ProcessingMode.swift
//  VTFramePro
//
//  5 种业务模式枚举 + 所需引擎能力 / 链路类型描述（L5 Model 层）。
//  对应 PRD R-01~R-05。
//

import Foundation

/// VTFramePro 的 5 种业务模式。
///
/// - 实时链路（R-01/02/03）：AVCaptureSession 摄像头输入，720p 上限，端到端 <150ms。
/// - 离线链路（R-04/05）：AVAssetReader/Writer 本地视频处理，HEVC 输出。
enum ProcessingMode: String, CaseIterable, Sendable, Codable, Identifiable {
    /// 实时补帧：摄像头输入，仅帧插值（R-01）。
    case realtimeInterpolation
    /// 实时超分：摄像头输入，仅超分（R-02）。
    case realtimeSuperResolution
    /// 实时补帧+超分串联：插值 → 超分（R-03）。
    case realtimeCombined
    /// 离线补帧：本地视频帧插值，分辨率不变，HEVC（R-04）。
    case offlineInterpolation
    /// 离线超分：本地视频 x2 超分（VT 高质量档），HEVC（R-05）。
    case offlineSuperResolution

    var id: String { rawValue }

    /// 面向用户的模式名称。
    var displayName: String {
        switch self {
        case .realtimeInterpolation: return "实时补帧"
        case .realtimeSuperResolution: return "实时超分"
        case .realtimeCombined: return "实时补帧+超分"
        case .offlineInterpolation: return "离线补帧"
        case .offlineSuperResolution: return "离线超分"
        }
    }

    /// 模式一句话说明（首页卡片副标题）。
    var subtitle: String {
        switch self {
        case .realtimeInterpolation: return "摄像头 30fps → 60fps 流畅预览"
        case .realtimeSuperResolution: return "摄像头画面实时高清增强"
        case .realtimeCombined: return "插值 + 超分流水线串联"
        case .offlineInterpolation: return "本地视频 2 倍帧率，HEVC 输出"
        case .offlineSuperResolution: return "本地视频 2 倍分辨率，HEVC 输出"
        }
    }

    /// SF Symbols 图标名。
    var systemImage: String {
        switch self {
        case .realtimeInterpolation: return "video.badge.plus"
        case .realtimeSuperResolution: return "arrow.up.left.and.arrow.down.right.video"
        case .realtimeCombined: return "link"
        case .offlineInterpolation: return "film.stack"
        case .offlineSuperResolution: return "square.resize.up"
        }
    }

    /// 是否实时链路（摄像头链路）。
    var isRealtime: Bool {
        switch self {
        case .realtimeInterpolation, .realtimeSuperResolution, .realtimeCombined:
            return true
        case .offlineInterpolation, .offlineSuperResolution:
            return false
        }
    }

    /// 该模式需要的引擎能力集合（用于 EngineRegistry 可用性判定）。
    var requiredCapabilities: Set<EngineCapability> {
        switch self {
        case .realtimeInterpolation, .offlineInterpolation:
            return [.frameInterpolation]
        case .realtimeSuperResolution, .offlineSuperResolution:
            return [.superResolution]
        case .realtimeCombined:
            return [.frameInterpolation, .superResolution]
        }
    }

    /// 实时链路的输出节拍倍率（补帧输出 2× 节拍）。
    var outputCadenceMultiplier: Int {
        switch self {
        case .realtimeInterpolation, .realtimeCombined: return 2
        default: return 1
        }
    }

    /// 是否需要串联（先插值后超分）。
    var isChained: Bool {
        self == .realtimeCombined
    }
}
