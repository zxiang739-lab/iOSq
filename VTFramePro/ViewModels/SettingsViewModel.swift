//
//  SettingsViewModel.swift
//  VTFramePro
//
//  设置 ViewModel：默认参数 / 权限状态 / 缓存清理 / 存储占用（L2）。
//  对应 PRD §3.2 设置页与 R-21（处理参数设置）。
//

import Foundation
import Observation
import OSLog

/// 设置 ViewModel。
///
/// 线程：@MainActor；参数修改即写 UserDefaults（ProcessingSettings.save）。
@Observable
@MainActor
final class SettingsViewModel {

    // MARK: - 可观察状态

    /// 默认处理参数——离线补帧倍率（计算属性：读 UserDefaults 事实源，写即持久化；
    /// 不用 didSet——@Observable 宏对带观察者的存储属性支持有约束）。
    var interpolationFactor: Int {
        get { dependencies.settings.interpolationFactor }
        set { mutate { $0.interpolationFactor = newValue } }
    }
    /// 实时画质档位。
    var realtimeQualityTier: RealtimeQualityTier {
        get { dependencies.settings.realtimeQualityTier }
        set { mutate { $0.realtimeQualityTier = newValue } }
    }
    /// 摄像头权限状态。
    private(set) var cameraPermission: PermissionStatus = .notDetermined
    /// 照片库（读取）权限状态。
    private(set) var photoPermission: PermissionStatus = .notDetermined
    /// 照片库（保存）权限状态。
    private(set) var photoAddPermission: PermissionStatus = .notDetermined
    /// 存储占用文案（模型 + 临时文件）。
    private(set) var storageSummary: String = "计算中…"
    /// 缓存清理完成提示（View Toast）。
    private(set) var cacheClearedNotice: String?

    // MARK: - 依赖

    private let dependencies: AppDependencies
    private let logger = Logger(subsystem: "com.vtframepro", category: "ui")

    // MARK: - 初始化

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - 刷新

    /// 进入页面刷新权限状态与存储占用（幂等）。
    func refresh() async {
        let permissionService = dependencies.permissionService
        cameraPermission = permissionService.status(of: .camera)
        photoPermission = permissionService.status(of: .photoLibrary)
        photoAddPermission = permissionService.status(of: .photoAddOnly)

        let modelBytes = await dependencies.modelLibraryService.storageBytes()
        let temporaryBytes = Self.temporaryDirectoryBytes()
        storageSummary = "模型 \(Self.format(modelBytes)) · 临时文件 \(Self.format(temporaryBytes))"
    }

    // MARK: - 缓存清理

    /// 清理临时文件（离线中间产物/残留源文件，§9.3 临时文件防线）。
    func clearCaches() {
        OfflineProcessingService.cleanupTemporaryDirectory()
        cacheClearedNotice = "临时文件已清理"
        logger.notice("临时文件已清理")
        Task { await refresh() }
    }

    // MARK: - 私有

    /// 参数变更写回（load → 改 → save，保持单点持久化）。
    private func mutate(_ transform: (inout ProcessingSettings) -> Void) {
        var settings = ProcessingSettings.load()
        transform(&settings)
        settings.save()
    }

    /// 临时目录大小。
    private static func temporaryDirectoryBytes() -> Int64 {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "vtframepro", directoryHint: .isDirectory)
        return (try? FileManager.default.directorySize(at: directory)) ?? 0
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
