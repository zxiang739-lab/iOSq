//
//  HomeView.swift
//  VTFramePro
//
//  首页：玻璃大卡片模式入口网格 + 当前引擎 + 置灰原因提示（L1 视图层）。
//  对应 PRD §3.2 主界面（R-28 置灰、R-31 降级横幅）。
//

import SwiftUI

/// 首页视图。
///
/// 5 模式入口卡片（玻璃材质大卡片网格）：
/// - 实时三种 → 导航至 RealtimePreviewView；
/// - 离线两种 → 切换到「离线任务」Tab；
/// - 不可用模式置灰 + 原因提示（R-28）；
/// - 顶部：当前引擎/VT 状态 + 降级横幅（R-31）。
struct HomeView: View {

    /// 首页 ViewModel（构造注入，@Observable 绑定）。
    @State var viewModel: HomeViewModel
    /// Tab 选择联动（离线卡片点击切 Tab）。
    @Binding var tabSelection: Int

    /// 双列网格。
    private let columns = [GridItem(.flexible(), spacing: 14),
                           GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 顶部状态条：VT 引擎状态。
                    vtStateBanner

                    // 降级横幅（引擎自动切换提示，§2.3）。
                    if let notice = viewModel.fallbackNotice {
                        Label(notice, systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassPanel(cornerRadius: 14)
                    }

                    // 模式卡片网格。
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(viewModel.entries) { entry in
                            modeCard(entry)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("VTFramePro")
            .onAppear {
                // 进入页面重算入口可用性（回前台重检后同样经此刷新）。
                viewModel.refresh()
            }
        }
    }

    // MARK: - VT 状态条

    private var vtStateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
            Text("系统 VT 引擎")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(viewModel.vtEngineState.displayName)
                .font(.caption)
                .foregroundStyle(viewModel.vtEngineState.isUsable ? Color.green : Color.secondary)
        }
        .padding(12)
        .glassPanel(cornerRadius: 16)
    }

    // MARK: - 模式卡片

    @ViewBuilder
    private func modeCard(_ entry: HomeViewModel.ModeEntry) -> some View {
        let card = VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: entry.mode.systemImage)
                    .font(.title2)
                Spacer()
                if !entry.isEnabled {
                    Image(systemName: "slash.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Text(entry.mode.displayName)
                .font(.headline)
            Text(entry.mode.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let engineName = entry.engineName, entry.isEnabled {
                Text("引擎：\(engineName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // R-28：置灰原因提示。
            if let reason = entry.disabledReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 20)
        .opacity(entry.isEnabled ? 1 : 0.5)

        if entry.isEnabled {
            if entry.mode.isRealtime {
                // 实时模式 → 实时预览页。
                NavigationLink {
                    RealtimePreviewView(
                        viewModel: RealtimeViewModel(
                            mode: entry.mode,
                            dependencies: viewModel.dependencies
                        )
                    )
                } label: {
                    card
                }
                .buttonStyle(.plain)
            } else {
                // 离线模式 → 切「离线任务」Tab（Tab 序 1）。
                Button {
                    tabSelection = 1
                } label: {
                    card
                }
                .buttonStyle(.plain)
            }
        } else {
            // 不可用：纯展示（点击无响应，原因已展示）。
            card
        }
    }
}
