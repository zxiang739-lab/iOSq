//
//  SettingsView.swift
//  VTFramePro
//
//  设置页：默认参数 / 权限状态 / 存储占用 / 关于（L1 视图层）。
//  对应 PRD §3.2 设置页（R-21 参数、R-11 权限跳转）。
//

import SwiftUI
import UIKit

/// 设置视图。
struct SettingsView: View {

    /// 设置 ViewModel（构造注入）。
    @State var viewModel: SettingsViewModel

    /// 跳系统设置（openURL 环境动作）。
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                // 默认处理参数（R-21）。
                Section("默认处理参数") {
                    // 补帧倍率（实时链路锁 x2，§10-1；此处为离线默认值，x4 预留）。
                    Picker("离线补帧倍率", selection: $viewModel.interpolationFactor) {
                        Text("x2").tag(2)
                        Text("x4（预留，暂未开放）").tag(4)
                    }
                    .disabled(true) // 首版锁定 x2（§10-1）
                    .foregroundStyle(.secondary)

                    Picker("实时画质档位", selection: $viewModel.realtimeQualityTier) {
                        ForEach(RealtimeQualityTier.allCases, id: \.self) { tier in
                            Text(tier.displayName).tag(tier)
                        }
                    }
                }

                // 权限状态（R-11 跳转系统设置）。
                Section("权限状态") {
                    permissionRow(title: "摄像头", status: viewModel.cameraPermission)
                    permissionRow(title: "照片库（读取）", status: viewModel.photoPermission)
                    permissionRow(title: "照片库（保存）", status: viewModel.photoAddPermission)
                    Button("前往系统设置") {
                        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                            openURL(settingsURL)
                        }
                    }
                }

                // 存储占用与缓存清理。
                Section("存储") {
                    LabeledContent("占用", value: viewModel.storageSummary)
                    Button("清理临时文件") {
                        viewModel.clearCaches()
                    }
                    if let notice = viewModel.cacheClearedNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                // 关于。
                Section("关于") {
                    LabeledContent("版本", value: "1.0")
                    LabeledContent("平台", value: "iOS 26+ · 仅 iPhone")
                    LabeledContent("引擎", value: "VTFrameProcessor + CoreML 双引擎")
                    Text("本应用不内置任何模型；系统模型由 iOS 管理，自定义模型由您导入并仅在本地运行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .task {
                await viewModel.refresh()
            }
        }
    }

    // MARK: - 权限行

    private func permissionRow(title: String, status: PermissionStatus) -> some View {
        LabeledContent(title) {
            Text(status.displayName)
                .foregroundStyle(status.isGranted ? Color.green : Color.red)
        }
    }
}
