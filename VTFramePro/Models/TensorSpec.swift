//
//  TensorSpec.swift
//  VTFramePro
//
//  张量规格值类型 + 校验结果（L5 Model 层）。
//  校验规则见 PRD §3.4 第 5 条（R-32）。
//

import Foundation

// MARK: - 张量像素格式

/// 导入模型张量的像素/通道布局约定。
enum TensorPixelFormat: String, Sendable, Codable {
    /// RGB 三通道交错（interleaved）。
    case rgbInterleaved
    /// BGRA 四通道（kCVPixelFormatType_32BGRA 语义）。
    case bgra

    /// 通道数（校验规则②：通道数与像素格式一致）。
    var channelCount: Int {
        switch self {
        case .rgbInterleaved: return 3
        case .bgra: return 4
        }
    }

    var displayName: String {
        switch self {
        case .rgbInterleaved: return "RGB 三通道"
        case .bgra: return "BGRA 四通道"
        }
    }
}

// MARK: - 张量规格

/// 单个输入/输出张量的静态规格。
///
/// 形状统一以 (batch, channels, height, width) 四元组表达；
/// 通道在维的位置（NCHW/NHWC）由 CoreML 描述转换时归一化，此处不关心物理布局。
struct TensorSpec: Sendable, Codable, Equatable {
    /// 张量名称（CoreML feature name）。
    var name: String
    /// 批次（校验规则④：必须为 1）。
    var batch: Int
    /// 通道数（3 或 4）。
    var channels: Int
    /// 空间高。
    var height: Int
    /// 空间宽。
    var width: Int
    /// 像素格式（由通道数推导）。
    var pixelFormat: TensorPixelFormat
    /// 是否为静态形状（校验规则⑤：不接受动态 shape）。
    var isStatic: Bool

    /// 一行式摘要，如「frame0 · 1×3×720×1280 · RGB」。
    var summary: String {
        "\(name) · \(batch)×\(channels)×\(height)×\(width) · \(pixelFormat.displayName)"
    }
}

// MARK: - 模型张量契约

/// 一个导入模型的完整输入/输出张量契约（校验通过后入库保存）。
struct TensorContract: Sendable, Codable, Equatable {
    /// 输入张量列表（补帧 2 个、超分 1 个）。
    var inputs: [TensorSpec]
    /// 输出张量列表（均为 1 个）。
    var outputs: [TensorSpec]

    /// 摘要文案（模型库列表展示）。
    var summary: String {
        let inputText = inputs.map(\.summary).joined(separator: "；")
        let outputText = outputs.map(\.summary).joined(separator: "；")
        return "输入[\(inputText)] 输出[\(outputText)]"
    }
}
