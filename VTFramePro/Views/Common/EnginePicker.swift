//
//  EnginePicker.swift
//  VTFramePro
//
//  引擎/模型选择组件（含不可用置灰）（L1 视图层公共组件）。
//  对应 PRD R-20（引擎与模型切换）与 R-28（不可用置灰）。
//

import SwiftUI

/// 引擎选择器。
///
/// 展示指定能力下全部已注册引擎（系统 VT + 导入模型），
/// 不可用引擎置灰并附状态原因；选中回调交给 ViewModel 编排。
struct EnginePicker: View {

    /// DI 容器（读取注册表引擎列表）。
    @Environment(AppDependencies.self) private var dependencies
    /// 目标能力集合（仅展示声明覆盖全部所需能力的引擎——
    /// 串联模式要求单引擎同时具备补帧+超分，§3.1-① 单引擎串联约定）。
    let requiredCapabilities: Set<EngineCapability>
    /// 当前选中引擎标识。
    let selectedEngineID: String?
    /// 选中回调（不可用引擎不触发）。
    let onSelect: (String) -> Void

    var body: some View {
        let engines = dependencies.engineRegistry.engines
            .filter { $0.capabilities.isSuperset(of: requiredCapabilities) }

        VStack(alignment: .leading, spacing: 8) {
            Text("引擎")
                .font(.caption)
                .foregroundStyle(.secondary)

            if engines.isEmpty {
                Text("暂无可用引擎，请先到「模型库」导入模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(engines, id: \.engineID) { engine in
                        engineChip(engine)
                    }
                }
            }
        }
    }

    // MARK: - 引擎胶囊

    @ViewBuilder
    private func engineChip(_ engine: any AIEngine) -> some View {
        let isUsable = engine.state.isUsable
        let isSelected = engine.engineID == selectedEngineID

        Button {
            if isUsable {
                onSelect(engine.engineID)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                    .font(.caption.weight(isSelected ? .bold : .regular))
                    .lineLimit(1)
                Text(engine.state.displayName)
                    .font(.caption2)
                    .foregroundStyle(isUsable ? .secondary : .red)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassPanel(cornerRadius: 12, highlighted: isSelected)
            // R-28：不可用置灰。
            .opacity(isUsable ? 1 : 0.45)
        }
        .disabled(!isUsable)
        .accessibilityLabel("\(engine.displayName)，\(engine.state.displayName)")
    }
}
