//
//  ModelLibraryView.swift
//  VTFramePro
//
//  模型管理页：引擎分区列表（系统 VT + 导入模型）+ 导入/删除/设当前（L1 视图层）。
//  对应 PRD §3.2 模型管理页（R-13 导入、R-19 元信息、R-20 设当前、R-32 校验原因）。
//

import SwiftUI
import UniformTypeIdentifiers

/// 模型库视图。
///
/// 分区：
/// - 系统 VT 引擎卡（能力检测状态 + 下载三态 + 重试）；
/// - 导入模型列表（名称/用途/张量摘要/大小 + 设为当前 + 删除）；
/// - 导入入口（文件选择器 mlpackage + 用途选择）；
/// - 校验失败：逐条原因弹窗（R-32）。
struct ModelLibraryView: View {

    /// 模型库 ViewModel（构造注入）。
    @State var viewModel: ModelLibraryViewModel

    /// 文件选择器显隐。
    @State private var isImporterPresented = false

    /// mlpackage UTI（com.apple.coreml.model-package 登记于 Info.plist）。
    private let modelContentTypes: [UTType] = {
        var types: [UTType] = []
        if let packageType = UTType("com.apple.coreml.model-package") {
            types.append(packageType)
        }
        if let compiledType = UTType("com.apple.coreml.model") {
            types.append(compiledType)
        }
        return types.isEmpty ? [.item] : types
    }()

    var body: some View {
        NavigationStack {
            List {
                // 系统 VT 引擎分区。
                Section("系统引擎") {
                    vtEngineCard
                }

                // 导入模型分区。
                Section("导入模型（\(viewModel.models.count)）") {
                    if viewModel.models.isEmpty {
                        Text("尚未导入模型。\n支持补帧（2 帧输入→1 帧输出）与超分（1 帧输入→1 帧输出，x2/x4）mlpackage。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.models) { model in
                            modelRow(model)
                        }
                    }
                }

                // 导入入口。
                Section {
                    Picker("导入用途", selection: $viewModel.importKind) {
                        ForEach(EngineCapability.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    Button {
                        isImporterPresented = true
                    } label: {
                        if viewModel.isImporting {
                            HStack {
                                ProgressView()
                                Text("校验导入中…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("导入 mlpackage", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isImporting)
                } footer: {
                    Text("模型仅保存于本机沙盒，可经「文件」App 管理；导入时校验张量规格，不合格将被拒绝。")
                }
            }
            .navigationTitle("模型库")
            .task {
                await viewModel.refresh()
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: modelContentTypes,
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await viewModel.importPickedModel(from: url) }
            }
            // R-32：校验失败逐条原因。
            .alert("模型校验未通过",
                   isPresented: Binding(
                    get: { viewModel.validationFailureReasons != nil },
                    set: { if !$0 { viewModel.validationFailureReasons = nil } }
                   )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text((viewModel.validationFailureReasons ?? [])
                    .map { "· \($0)" }
                    .joined(separator: "\n"))
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

    // MARK: - 系统 VT 引擎卡

    private var vtEngineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cpu")
                Text("系统 VT 引擎")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(viewModel.vtEngineState.displayName)
                    .font(.caption)
                    .foregroundStyle(viewModel.vtEngineState.isUsable ? Color.green : Color.secondary)
            }

            // 下载失败：重试按钮（R-30）。
            if case .downloadFailed = viewModel.vtEngineState {
                Button("重试下载") {
                    Task { await viewModel.retryVTDownload() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }

            // 设为当前（两种能力各一入口）。
            if viewModel.vtEngineState.isUsable {
                HStack(spacing: 8) {
                    ForEach(EngineCapability.allCases, id: \.self) { capability in
                        let isActive = viewModel.activeEngineNames[capability] == "系统 VT 引擎"
                        Button {
                            viewModel.setVTActive(for: capability)
                        } label: {
                            Text(isActive ? "当前\(capability.displayName)引擎 ✓"
                                        : "设为\(capability.displayName)引擎")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isActive)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 模型行（R-19 元信息）

    @ViewBuilder
    private func modelRow(_ model: ImportedModel) -> some View {
        let isActive = viewModel.activeEngineNames[model.declaredKind] == model.displayName
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: model.declaredKind == .frameInterpolation
                      ? "video.badge.plus" : "arrow.up.left.and.arrow.down.right.video")
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(model.declaredKind.displayName)模型 · \(model.fileSizeDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Text("当前")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            // 张量规格摘要（R-19）。
            Text(model.tensorContract.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                if !isActive {
                    Button("设为当前") {
                        viewModel.setActive(modelID: model.id)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button(role: .destructive) {
                    Task { await viewModel.delete(modelID: model.id) }
                } label: {
                    Text("删除")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
