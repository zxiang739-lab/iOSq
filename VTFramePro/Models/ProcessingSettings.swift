//
//  ProcessingSettings.swift
//  VTFramePro
//
//  默认处理参数 + UserDefaults 持久化（L5 Model 层）。
//  对应 PRD R-21 与 ARCHITECTURE.md §10-1（实时锁 x2）。
//

import Foundation

/// 实时链路画质档位（R-29 分档 / R-21 设置项）。
enum RealtimeQualityTier: String, CaseIterable, Sendable, Codable {
    /// 性能优先：关超分级 / 最低推理开销。
    case performance
    /// 均衡（默认）。
    case balanced
    /// 画质优先：允许更高推理开销。
    case quality

    var displayName: String {
        switch self {
        case .performance: return "性能优先"
        case .balanced: return "均衡"
        case .quality: return "画质优先"
        }
    }
}

/// App 级默认处理参数。
///
/// 持久化：Codable → JSON → UserDefaults（键 `com.vtframepro.settings`）。
/// 线程：值类型，读写发生在 @MainActor 的 SettingsViewModel，无并发风险。
struct ProcessingSettings: Sendable, Codable, Equatable {

    // MARK: 补帧倍率

    /// 离线补帧倍率（实时链路锁死 x2，见 §10-1；UI 首版仅开放 x2，字段为 x4 预留）。
    var interpolationFactor: Int

    /// 实时链路补帧倍率：架构拍板锁死 x2，常量暴露避免误改。
    static let realtimeInterpolationFactor: Int = 2

    // MARK: 画质档位

    /// 实时链路画质档位（默认均衡）。
    var realtimeQualityTier: RealtimeQualityTier

    // MARK: 默认值

    static let `default` = ProcessingSettings(
        interpolationFactor: 2,
        realtimeQualityTier: .balanced
    )

    // MARK: UserDefaults 持久化

    /// UserDefaults 存储键。
    private static let storageKey = "com.vtframepro.settings"

    /// 从 UserDefaults 加载（无记录或损坏时回落默认值）。
    static func load(defaults: UserDefaults = .standard) -> ProcessingSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(ProcessingSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// 保存到 UserDefaults。
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
