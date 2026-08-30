//
//  PermissionService.swift
//  VTFramePro
//
//  权限查询与申请（L3 媒体服务层）。
//  对应 PRD R-11：摄像头 / 照片库读取 / 照片库保存。
//

import Foundation
import AVFoundation
import Photos

// MARK: - 权限状态

/// 权限状态（统一抽象，屏蔽 AVFoundation / Photos 两套枚举差异）。
enum PermissionStatus: Sendable, Equatable {
    /// 未决定（可申请）。
    case notDetermined
    /// 已授权。
    case authorized
    /// 已拒绝（需引导至系统设置）。
    case denied
    /// 受限（家长控制等，不可申请）。
    case restricted
    /// 部分授权（照片库 limited）。
    case limited

    /// 是否可用（授权或部分授权）。
    var isGranted: Bool {
        self == .authorized || self == .limited
    }

    var displayName: String {
        switch self {
        case .notDetermined: return "未申请"
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .limited: return "部分授权"
        }
    }
}

// MARK: - 权限服务

/// 权限查询与申请服务。
///
/// - 查询为同步本地调用（系统缓存状态）；
/// - 申请为 async（系统弹窗回调桥接）；
/// - 线程：无内部状态，Sendable，可在任意线程调用。
struct PermissionService: Sendable {

    init() {}

    // MARK: - 查询

    /// 查询指定权限当前状态。
    func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .camera:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        case .photoLibrary:
            return Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        case .photoAddOnly:
            return Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        }
    }

    // MARK: - 申请

    /// 申请指定权限（已决定时直接返回当前状态，不重复弹窗）。
    ///
    /// - Parameter kind: 权限种类。
    /// - Returns: 申请后的最终状态。
    func request(_ kind: PermissionKind) async -> PermissionStatus {
        let current = status(of: kind)
        guard current == .notDetermined else { return current }
        switch kind {
        case .camera:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .authorized : .denied
        case .photoLibrary:
            return Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        case .photoAddOnly:
            return Self.map(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
        }
    }

    // MARK: - 私有：枚举映射

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .denied
        }
    }
}
