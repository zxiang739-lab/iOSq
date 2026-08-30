//
//  VTFrameProApp.swift
//  VTFramePro
//
//  @main 入口：注入 AppDependencies；scenePhase 监听触发引擎重检。
//  对应 ARCHITECTURE.md §3.3-3（回前台重检 isSupported）。
//

import SwiftUI

/// VTFramePro App 入口。
///
/// 启动序列：
/// 1. `@State` 构造 `AppDependencies`（同步，无 IO）；
/// 2. `.task` 中执行 `bootstrap()`（注册引擎、加载清单、首次能力检测）；
/// 3. `scenePhase` 回前台时 `refreshStates()` 重检（防系统状态变化）。
@main
struct VTFrameProApp: App {

    /// DI 容器（App 生命周期单例）。
    @State private var dependencies = AppDependencies()

    /// 场景相位（前台/后台切换监听）。
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(dependencies)
                .task {
                    // 启动引导：注册引擎 + 加载模型清单 + 首次能力检测。
                    await dependencies.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // 回前台重检引擎能力（VT isSupported 可能随系统状态变化，§3.3-3）。
                    guard newPhase == .active else { return }
                    Task { @MainActor in
                        await dependencies.engineRegistry.refreshStates()
                    }
                }
        }
    }
}
