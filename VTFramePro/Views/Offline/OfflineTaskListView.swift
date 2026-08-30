//
//  OfflineTaskListView.swift
//  VTFramePro
//
//  离线任务页：导入入口 + 严格串行队列列表（进度/取消/完成跳转）（L1 视图层）。
//  对应 PRD §3.2 离线任务页（R-14 串行队列、R-16 保存提示）。
//

import SwiftUI
import UniformTypeIdentifiers

/// 离线任务列表视图。
///
/// 流程：选模式/引擎 → 文件选择器导入视频 → 建任务排队 →
/// 列表实时进度（taskUpdates 流）→ 取消 / 完成点击进入播放器回放。
struct OfflineTaskListView: View {

    /// 离线任务 ViewModel（构造注入）。
    @State var viewModel: OfflineTaskViewModel

    /// DI 容器（EnginePicker 读取注册表）。
    @Environment(AppDependencies.self) private var dependencies

    /// 待创建任务的模式（默认离线补帧）。
    @State private var pendingMode: ProcessingMode = .offlineInterpolation
    /// 文件选择器显隐。
    @State private var isImporterPresented = false

    var body: some View {
        NavigationStack {
            List {
                // 创建区：模式 + 引擎 + 导入按钮。
                Section {
                    Picker("模式", selection: $pendingMode) {
                        Text(ProcessingMode.offlineInterpolation.displayName)
                            .tag(ProcessingMode.offlineInterpolation)
                        Text(ProcessingMode.offlineSuperResolution.displayName)
                            .tag(ProcessingMode.offlineSuperResolution)
                    }
                    .pickerStyle(.segmented)

                    EnginePicker(
                        requiredCapabilities: pendingMode.requiredCapabilities,
                        selectedEngineID: viewModel.selectedEngineID,
                        onSelect: { viewModel.selectedEngineID = $0 }
                    )

                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("导入视频并创建任务", systemImage: "plus.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } header: {
                    Text("新建任务")
                } footer: {
                    Text("任务严格串行执行，输出 HEVC 视频自动保存到相册。")
                }

                // 队列区。
                Section("任务队列（\(viewModel.tasks.count)）") {
                    if viewModel.tasks.isEmpty {
                        Text("暂无任务")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.tasks) { task in
                            taskRow(task)
                        }
                    }
                }
            }
            .navigationTitle("离线任务")
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.movie, .video],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await viewModel.importVideo(from: url, mode: pendingMode) }
            }
            // 完成回放导航。
            .navigationDestination(item: $viewModel.playbackURL) { url in
                GlassPlayerView(url: url)
            }
            .alert("提示",
                   isPresented: Binding(
                    get: { viewModel.activeError != nil },
                    set: { if !$0 { viewModel.activeError = nil } }
                   ),
                   presenting: viewModel.activeError) { _ in
                Button("知道了", role: .cancel) {}
            } message: { error in
                Text(error.errorDescription ?? "未知错误")
            }
        }
    }

    // MARK: - 任务行

    @ViewBuilder
    private func taskRow(_ task: OfflineTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: task.mode.systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.sourceFileName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(task.mode.displayName) · \(viewModel.engineName(for: task))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(task)
            }

            // 执行中：进度条 + 取消按钮（R-14）。
            if case .running(let progress) = task.status {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                    Button("取消") {
                        Task { await viewModel.cancel(taskID: task.id) }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }

            // 排队中：可取消。
            if task.status == .queued {
                HStack {
                    Spacer()
                    Button("取消排队") {
                        Task { await viewModel.cancel(taskID: task.id) }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }

            // 完成：保存提示 + 点击回放。
            if case .completed = task.status {
                Button {
                    viewModel.openPlayback(for: task)
                } label: {
                    Label("已保存到相册 · 点击回放", systemImage: "play.rectangle")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 状态徽标

    @ViewBuilder
    private func statusBadge(_ task: OfflineTask) -> some View {
        let (text, color): (String, Color) = {
            switch task.status {
            case .queued: return ("排队中", .secondary)
            case .running(let progress):
                return (String(format: "%.0f%%", progress * 100), .blue)
            case .cancelled: return ("已取消", .secondary)
            case .failed: return ("失败", .red)
            case .completed: return ("已完成", .green)
            }
        }()
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }
}
