//
//  TensorValidator.swift
//  VTFramePro
//
//  mlpackage 张量规格校验（L4 AI 引擎协议层）。
//  对应 PRD §3.4 第 5 条五条校验规则（R-32）。
//

import Foundation
import CoreML
import CoreVideo
import OSLog

/// mlpackage 编译桥接（L4 收敛 CoreML 符号，供 L3 调用，§1.2）。
///
/// `MLModel.compileModel(at:)` 是 CoreML API，按分层铁律不得出现在 L3；
/// L3 的 ModelLibraryService 经此桥接完成编译，编译产物由调用方负责清理。
enum TensorValidatorCompiler {
    /// 编译 mlpackage 为 mlmodelc（系统临时目录）。
    /// - Parameter modelURL: mlpackage 路径。
    /// - Returns: 编译产物 URL（临时目录，调用方用毕删除）。
    /// - Throws: `AppError.ioFailed`（编译失败）。
    static func compile(modelURL: URL) throws -> URL {
        do {
            return try MLModel.compileModel(at: modelURL)
        } catch {
            throw AppError.ioFailed(underlying: "模型编译失败：\(error.localizedDescription)")
        }
    }
}

/// 张量规格校验器。
///
/// 校验规则（PRD §3.4-5，任一不满足即拒绝导入并列出全部原因）：
/// 1. 输入/输出张量数与声明用途匹配（补帧：2 帧输入→1 帧输出；超分：1 帧输入→1 帧输出）；
/// 2. 通道数与像素格式一致（3 通道 RGB 或 4 通道 BGRA）；
/// 3. 超分模型输出 H/W 必须为输入的整数倍（首版约定 x2/x4）；
/// 4. 批次 = 1；
/// 5. 形状静态（不接受动态 shape）。
struct TensorValidator: Sendable {

    private let logger = Logger(subsystem: "com.vtframepro", category: "engine")

    init() {}

    // MARK: - 校验入口

    /// 校验 mlpackage 的张量规格。
    ///
    /// - Parameters:
    ///   - modelURL: 沙盒内 mlpackage（或已编译 mlmodelc）路径。
    ///   - declaredKind: 导入时声明的用途（补帧/超分）。
    /// - Returns: 校验通过的张量契约（输入 + 输出规格）。
    /// - Throws: `AppError.modelValidationFailed(reasons:)`（列全部失败原因）；
    ///   `AppError.ioFailed`（模型无法加载/编译）。
    func validate(modelURL: URL, declaredKind: EngineCapability) throws -> TensorContract {
        // 加载模型描述（compileModel 由 ModelLibraryService 完成，此处 URL 已可加载）。
        let model: MLModel
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw AppError.ioFailed(underlying: "模型加载失败：\(error.localizedDescription)")
        }
        return try validate(description: model.modelDescription, declaredKind: declaredKind)
    }

    // MARK: - 描述校验（纯逻辑，可单测）

    /// 基于模型描述执行五条规则校验。
    func validate(description: MLModelDescription,
                  declaredKind: EngineCapability) throws -> TensorContract {
        var reasons: [String] = []

        // ---- 提取图像类输入/输出（非图像特征如 timestep 标量不计入帧张量数）----
        let imageInputs = description.inputDescriptionsByName
            .filter { Self.isImageLike($0.value) }
        let imageOutputs = description.outputDescriptionsByName
            .filter { Self.isImageLike($0.value) }

        // ---- 规则①：张量数与声明用途匹配 ----
        let expectedInputs = declaredKind == .frameInterpolation ? 2 : 1
        if imageInputs.count != expectedInputs {
            reasons.append("输入帧张量数应为 \(expectedInputs) 个（\(declaredKind.displayName)），实际 \(imageInputs.count) 个")
        }
        if imageOutputs.count != 1 {
            reasons.append("输出帧张量数应为 1 个，实际 \(imageOutputs.count) 个")
        }

        // ---- 逐张量提取规格（规则②④⑤）----
        let inputSpecs = imageInputs
            .sorted { $0.key < $1.key }
            .compactMap { Self.spec(from: $0.value, name: $0.key, reasons: &reasons) }
        let outputSpecs = imageOutputs
            .sorted { $0.key < $1.key }
            .compactMap { Self.spec(from: $0.value, name: $0.key, reasons: &reasons) }

        // ---- 规则③：超分输出 H/W 为输入整数倍（x2/x4）----
        if declaredKind == .superResolution,
           let input = inputSpecs.first, let output = outputSpecs.first {
            guard input.width > 0, input.height > 0 else {
                reasons.append("输入张量尺寸非法")
                throw AppError.modelValidationFailed(reasons: reasons)
            }
            let widthMultiple = output.width / input.width
            let heightMultiple = output.height / input.height
            let isIntegralMultiple = (output.width % input.width == 0)
                && (output.height % input.height == 0)
                && widthMultiple == heightMultiple
            let isSupportedFactor = [2, 4].contains(widthMultiple)
            if !isIntegralMultiple || !isSupportedFactor {
                reasons.append("超分输出尺寸 (\(output.width)×\(output.height)) 须为输入 (\(input.width)×\(input.height)) 的 x2/x4 整数倍")
            }
        }

        // ---- 补帧：两输入帧规格须一致 ----
        if declaredKind == .frameInterpolation, inputSpecs.count == 2 {
            let first = inputSpecs[0], second = inputSpecs[1]
            if first.width != second.width || first.height != second.height
                || first.channels != second.channels {
                reasons.append("补帧两个输入帧规格须一致（\(first.summary) vs \(second.summary)）")
            }
        }

        guard reasons.isEmpty else {
            logger.notice("张量校验失败，共 \(reasons.count) 项原因")
            throw AppError.modelValidationFailed(reasons: reasons)
        }

        let contract = TensorContract(inputs: inputSpecs, outputs: outputSpecs)
        logger.notice("张量校验通过: \(contract.summary)")
        return contract
    }

    // MARK: - 私有：特征判定

    /// 判定特征是否图像类（image 类型，或多维 multiArray 帧张量）。
    private static func isImageLike(_ feature: MLFeatureDescription) -> Bool {
        switch feature.type {
        case .image:
            return true
        case .multiArray:
            // 标量/向量（如 timestep）不算帧张量；3 维以上才算。
            guard let constraint = feature.multiArrayConstraint else { return false }
            return constraint.shape.count >= 3
        default:
            return false
        }
    }

    // MARK: - 私有：规格提取

    /// 从特征描述提取张量规格；不合法项追加原因并返回 nil。
    private static func spec(from feature: MLFeatureDescription,
                             name: String,
                             reasons: inout [String]) -> TensorSpec? {
        switch feature.type {
        case .image:
            guard let constraint = feature.imageConstraint else {
                reasons.append("「\(name)」图像约束缺失")
                return nil
            }
            // 像素格式映射：32BGRA / 32RGBA → 4 通道；其余按 RGB 三通道计（规则②）。
            let pixelFormat: TensorPixelFormat
            switch constraint.pixelsHigh > 0 ? constraint.pixelFormatType : 0 {
            case kCVPixelFormatType_32BGRA:
                pixelFormat = .bgra
            default:
                pixelFormat = .rgbInterleaved
            }
            return TensorSpec(
                name: name,
                batch: 1,
                channels: pixelFormat.channelCount,
                height: constraint.pixelsHigh,
                width: constraint.pixelsWide,
                pixelFormat: pixelFormat,
                isStatic: true
            )

        case .multiArray:
            guard let constraint = feature.multiArrayConstraint else {
                reasons.append("「\(name)」张量约束缺失")
                return nil
            }
            let shape = constraint.shape.map(\.intValue)
            // 形状静态性（规则⑤）：含 0/负值维度视为动态。
            let isStatic = shape.allSatisfy { $0 > 0 }
            if !isStatic {
                reasons.append("「\(name)」形状须为静态，不接受动态 shape（\(shape)）")
            }
            // 归一化为 (batch, channels, height, width)：
            // 4 维 [N,C,H,W] 或 [N,H,W,C]；3 维 [C,H,W]（batch=1）。
            let normalized = normalize(shape: shape)
            guard let (batch, channels, height, width) = normalized else {
                reasons.append("「\(name)」张量形状无法解析为图像帧（\(shape)）")
                return nil
            }
            // 批次（规则④）。
            if batch != 1 {
                reasons.append("「\(name)」批次须为 1，实际 \(batch)")
            }
            // 通道与像素格式一致性（规则②）。
            guard channels == 3 || channels == 4 else {
                reasons.append("「\(name)」通道数须为 3（RGB）或 4（BGRA），实际 \(channels)")
                return nil
            }
            return TensorSpec(
                name: name,
                batch: batch,
                channels: channels,
                height: height,
                width: width,
                pixelFormat: channels == 4 ? .bgra : .rgbInterleaved,
                isStatic: isStatic
            )

        default:
            reasons.append("「\(name)」类型不支持（仅接受 image / multiArray 帧张量）")
            return nil
        }
    }

    /// 将任意布局形状归一化为 (batch, channels, height, width)。
    ///
    /// 识别规则：通道维取值 ∈ {3, 4}；优先匹配 NCHW，其次 NHWC。
    private static func normalize(shape: [Int]) -> (Int, Int, Int, Int)? {
        switch shape.count {
        case 4:
            // NCHW：[N, C, H, W]
            if [3, 4].contains(shape[1]) {
                return (shape[0], shape[1], shape[2], shape[3])
            }
            // NHWC：[N, H, W, C]
            if [3, 4].contains(shape[3]) {
                return (shape[0], shape[3], shape[1], shape[2])
            }
            return nil
        case 3:
            // CHW：[C, H, W]（batch=1）
            if [3, 4].contains(shape[0]) {
                return (1, shape[0], shape[1], shape[2])
            }
            // HWC：[H, W, C]（batch=1）
            if [3, 4].contains(shape[2]) {
                return (1, shape[2], shape[0], shape[1])
            }
            return nil
        default:
            return nil
        }
    }
}
