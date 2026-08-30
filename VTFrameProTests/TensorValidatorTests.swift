//
//  TensorValidatorTests.swift
//  VTFrameProTests
//
//  张量规格校验器测试（规则级验证需真实 CoreML 模型）。
//  覆盖规则：PRD §3.4-5 五条校验规则（R-32）。
//
//  ⚠️ 可测性说明（重要）：
//  - `TensorValidator.validate(description:declaredKind:)` 依赖 `MLModelDescription`——
//    CoreML 未提供公开构造器，只能从真实 mlpackage 加载。规则级用例（像素格式、
//    张量数、通道数、超分整数倍、批次、静态形状）必须使用**真实模型文件**。
//  - 本文件提供两类测试：
//    ① 纯逻辑派生值测试（TensorPixelFormat/TensorSpec/TensorContract，见 TensorSpecTests）；
//    ② 模型驱动测试：若测试 Bundle 附带样本模型（SearchPaths 中放置）则执行，否则 XCTSkip，
//       不硬编失败。样本模型由用户在 Mac 端按 TEST_RUN_GUIDE「样本模型准备」放入。
//

import CoreML
import Foundation
import XCTest
@testable import VTFramePro

final class TensorValidatorTests: XCTestCase {

    /// 校验器本身可构造（Sendable、无副作用）。
    func testValidator_initIsFree() {
        let validator = TensorValidator()
        XCTAssertNotNil(validator)
    }

    /// 样本模型 URL：测试 Bundle 根目录下 optional/sample_models/<用途>.mlpackage。
    /// 由 Mac 端用户按 TEST_RUN_GUIDE 放入；缺失时对应用例 XCTSkip。
    private var sampleModelsDirectory: URL? {
        Bundle(for: Self.self).resourceURL?
            .appending(path: "sample_models", directoryHint: .isDirectory)
    }

    private func sampleModelURL(named name: String) -> URL? {
        guard let dir = sampleModelsDirectory else { return nil }
        let url = dir.appending(path: name, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 规则级测试（需真实模型；缺失则跳过）

    /// R-32 规则①/②/④/⑤ 综合：合法补帧模型通过，返回 2 入 1 出契约。
    func testValidate_interpolation_acceptsValidContract() throws {
        guard let url = sampleModelURL(named: "InterpolationValid.mlpackage") else {
            throw XCTSkip("未提供样本模型 InterpolationValid.mlpackage，跳过（真机必测项）")
        }
        let validator = TensorValidator()
        let contract = try validator.validate(modelURL: url, declaredKind: .frameInterpolation)
        XCTAssertEqual(contract.inputs.count, 2, "补帧 2 帧输入（规则①）")
        XCTAssertEqual(contract.outputs.count, 1, "补帧 1 帧输出（规则①）")
        for spec in contract.inputs + contract.outputs {
            XCTAssertEqual(spec.batch, 1, "批次 = 1（规则④）")
            XCTAssertTrue(spec.isStatic, "形状静态（规则⑤）")
            XCTAssertTrue([3, 4].contains(spec.channels), "通道 3/4（规则②）")
        }
    }

    /// R-32 规则①：补帧输入张量数非 2 → 拒绝且 reasons 列出具体条数。
    func testValidate_interpolation_wrongInputCount_rejects() throws {
        guard let url = sampleModelURL(named: "InterpolationWrongCount.mlpackage") else {
            throw XCTSkip("未提供样本模型 InterpolationWrongCount.mlpackage，跳过")
        }
        let validator = TensorValidator()
        XCTAssertThrowsError(try validator.validate(modelURL: url, declaredKind: .frameInterpolation)) { error in
            guard case AppError.modelValidationFailed(let reasons) = error else {
                return XCTFail("期望 modelValidationFailed，实际 \(error)")
            }
            XCTAssertFalse(reasons.isEmpty, "reasons 非空（R-32 需给出具体原因）")
            XCTAssertTrue(reasons.contains { $0.contains("输入帧张量数") },
                          "应包含张量数说明：\(reasons)")
        }
    }

    /// R-32 规则②：通道数非 3/4 → 拒绝并给出原因。
    func testValidate_badChannelCount_rejects() throws {
        guard let url = sampleModelURL(named: "BadChannels.mlpackage") else {
            throw XCTSkip("未提供样本模型 BadChannels.mlpackage，跳过")
        }
        let validator = TensorValidator()
        XCTAssertThrowsError(try validator.validate(modelURL: url, declaredKind: .frameInterpolation)) { error in
            guard case AppError.modelValidationFailed(let reasons) = error else {
                return XCTFail("期望 modelValidationFailed，实际 \(error)")
            }
            XCTAssertTrue(reasons.contains { $0.contains("通道数") }, "应包含通道数说明：\(reasons)")
        }
    }

    /// R-32 规则③：超分输出非 x2/x4 整数倍 → 拒绝。
    func testValidate_superResolution_nonIntegralOutput_rejects() throws {
        guard let url = sampleModelURL(named: "SuperResolutionBadScale.mlpackage") else {
            throw XCTSkip("未提供样本模型 SuperResolutionBadScale.mlpackage，跳过")
        }
        let validator = TensorValidator()
        XCTAssertThrowsError(try validator.validate(modelURL: url, declaredKind: .superResolution)) { error in
            guard case AppError.modelValidationFailed(let reasons) = error else {
                return XCTFail("期望 modelValidationFailed，实际 \(error)")
            }
            XCTAssertTrue(reasons.contains { $0.contains("整数倍") || $0.contains("x2/x4") },
                          "应包含尺寸整数倍说明：\(reasons)")
        }
    }

    /// R-32 规则④：批次 ≠ 1 → 拒绝。
    func testValidate_batchNotOne_rejects() throws {
        guard let url = sampleModelURL(named: "BatchNotOne.mlpackage") else {
            throw XCTSkip("未提供样本模型 BatchNotOne.mlpackage，跳过")
        }
        let validator = TensorValidator()
        XCTAssertThrowsError(try validator.validate(modelURL: url, declaredKind: .superResolution)) { error in
            guard case AppError.modelValidationFailed(let reasons) = error else {
                return XCTFail("期望 modelValidationFailed，实际 \(error)")
            }
            XCTAssertTrue(reasons.contains { $0.contains("批次") }, "应包含批次说明：\(reasons)")
        }
    }

    /// R-32 规则⑤：动态形状 → 拒绝。
    func testValidate_dynamicShape_rejects() throws {
        guard let url = sampleModelURL(named: "DynamicShape.mlpackage") else {
            throw XCTSkip("未提供样本模型 DynamicShape.mlpackage，跳过")
        }
        let validator = TensorValidator()
        XCTAssertThrowsError(try validator.validate(modelURL: url, declaredKind: .frameInterpolation)) { error in
            guard case AppError.modelValidationFailed(let reasons) = error else {
                return XCTFail("期望 modelValidationFailed，实际 \(error)")
            }
            XCTAssertTrue(reasons.contains { $0.contains("静态") }, "应包含动态 shape 说明：\(reasons)")
        }
    }

    /// 多原因聚合：reasons 数组同次校验列出全部失败项（R-32「列全部原因」）。——【P1-02 关注点】
    func testValidate_multipleFailures_listAllReasons() throws {
        guard let url = sampleModelURL(named: "MultiFail.mlpackage") else {
            throw XCTSkip("未提供样本模型 MultiFail.mlpackage，跳过")
        }
        let validator = TensorValidator()
        XCTAssertThrowsError(try validator.validate(modelURL: url, declaredKind: .frameInterpolation)) { error in
            guard case AppError.modelValidationFailed(let reasons) = error else {
                return XCTFail("期望 modelValidationFailed，实际 \(error)")
            }
            // 至少同时列出输入/输出张量数相关原因（理想为 ≥2 条）。
            XCTAssertGreaterThanOrEqual(reasons.count, 1)
        }
    }

    /// 模型加载失败 → AppError.ioFailed（错误域统一，R-12）。
    func testValidate_missingModel_throwsIO() {
        let validator = TensorValidator()
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist.mlmodelc")
        XCTAssertThrowsError(try validator.validate(modelURL: bogus, declaredKind: .frameInterpolation)) { error in
            guard case AppError.ioFailed = error else {
                return XCTFail("期望 ioFailed，实际 \(error)")
            }
        }
    }
}