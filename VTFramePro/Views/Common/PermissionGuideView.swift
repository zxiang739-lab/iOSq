//
//  PermissionGuideView.swift
//  VTFramePro
//
//  未授权引导视图（摄像头 / 照片库复用）（L1 视图层公共组件）。
//  对应 PRD R-11（未授权时友好引导）。
//

import SwiftUI
import UIKit

/// 权限引导视图。
///
/// 三态呈现：
/// - 未决定：展示「申请权限」按钮（现场弹系统申请窗）；
/// - 已拒绝/受限：展示引导文案 + 「前往设置」按钮（跳系统设置）；
/// - 已授权：不渲染本组件（调用方按状态决定是否嵌入）。
struct PermissionGuideView: View {

    /// 权限种类（图标与文案归因）。
    let kind: PermissionKind
    /// 当前权限状态。
    let status: PermissionStatus
    /// 「申请权限」回调（ViewModel 编排申请流程）。
    let onRequest: () -> Void

    /// 跳系统设置（SwiftUI openURL 环境动作）。
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text(titleText)
                .font(.headline)

            Text(messageText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if status == .notDetermined {
                Button("申请\(kind.displayName)权限", action: onRequest)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("前往系统设置") {
                    // UIApplication.openSettingsURLString：官方应用设置深链。
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        openURL(settingsURL)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .glassPanel(cornerRadius: 24)
        .padding(32)
    }

    // MARK: - 文案与图标

    private var iconName: String {
        switch kind {
        case .camera: return "camera.fill"
        case .photoLibrary, .photoAddOnly: return "photo.on.rectangle"
        }
    }

    private var titleText: String {
        status == .notDetermined
            ? "需要\(kind.displayName)权限"
            : "\(kind.displayName)权限未开启"
    }

    private var messageText: String {
        switch kind {
        case .camera:
            return "实时补帧与超分预览需要访问摄像头，画面仅在本地处理，不会上传。"
        case .photoLibrary:
            return "离线处理需要读取照片库中的视频素材。"
        case .photoAddOnly:
            return "处理完成的视频需要保存到您的相册。"
        }
    }
}
