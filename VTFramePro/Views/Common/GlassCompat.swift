//
//  GlassCompat.swift
//  VTFramePro
//
//  Liquid Glass 材质统一封装（L1 视图层公共组件）。
//
//  说明：本文件为架构文件清单（33 个）之外新增的第 34 个源文件——
//  将 iOS 26 Liquid Glass 修饰符收敛为单点封装，全部视图经 `.glassPanel` 使用，
//  若最终 SDK 修饰符命名有变，仅需改动本文件一处（与 ※SDK 约定同理）。
//

import SwiftUI

// MARK: - 玻璃面板修饰符

/// 统一液态玻璃面板修饰符。
///
/// - iOS 26+：原生 `.glassEffect(_:in:)`（Liquid Glass，R-17）；
/// - 兜底：`.ultraThinMaterial` 圆角材质（API 名漂移时保底可编译运行）。
struct GlassPanelModifier: ViewModifier {

    /// 圆角半径。
    var cornerRadius: CGFloat
    /// 高亮态（选中/激活，玻璃调亮）。
    var highlighted: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    highlighted ? .regular.tint(.accentColor.opacity(0.35)).interactive()
                                : .regular.interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            // 兜底分支：部署目标为 iOS 26，正常不会走到；
            // 保留仅为修饰符名漂移时的可编译保底。
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(highlighted ? 0.5 : 0.2), lineWidth: 1)
                )
        }
    }
}

// MARK: - View 便捷入口

extension View {
    /// 套统一液态玻璃面板。
    /// - Parameters:
    ///   - cornerRadius: 圆角半径（默认 16）。
    ///   - highlighted: 是否高亮（选中态）。
    func glassPanel(cornerRadius: CGFloat = 16, highlighted: Bool = false) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, highlighted: highlighted))
    }
}
