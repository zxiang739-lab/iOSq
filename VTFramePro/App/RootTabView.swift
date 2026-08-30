//
//  RootTabView.swift
//  VTFramePro
//
//  根导航：首页 / 离线任务 / 模型库 / 设置 四个 Tab。
//

import SwiftUI

/// 根 Tab 导航容器。
///
/// 四个一级页面均从 `@Environment` 取 `AppDependencies`，
/// 各自持有对应 ViewModel（@Observable 绑定，§1.2 第 5 条）。
struct RootTabView: View {

    /// DI 容器（由 VTFrameProApp 注入）。
    @Environment(AppDependencies.self) private var dependencies

    /// 当前 Tab 选择（首页离线卡片点击时联动切换）。
    @State private var tabSelection = 0

    var body: some View {
        TabView(selection: $tabSelection) {
            // 首页：5 模式入口 + 当前引擎展示。
            HomeView(
                viewModel: HomeViewModel(dependencies: dependencies),
                tabSelection: $tabSelection
            )
            .tabItem {
                Label("首页", systemImage: "house.fill")
            }
            .tag(0)

            // 离线任务：导入入口 + 串行队列。
            OfflineTaskListView(viewModel: OfflineTaskViewModel(dependencies: dependencies))
                .tabItem {
                    Label("离线任务", systemImage: "list.bullet.rectangle")
                }
                .tag(1)

            // 模型库：系统 VT + 导入模型分区管理。
            ModelLibraryView(viewModel: ModelLibraryViewModel(dependencies: dependencies))
                .tabItem {
                    Label("模型库", systemImage: "shippingbox.fill")
                }
                .tag(2)

            // 设置：默认参数 / 权限 / 存储 / 关于。
            SettingsView(viewModel: SettingsViewModel(dependencies: dependencies))
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
    }
}
