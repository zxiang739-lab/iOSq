//
//  AppErrorTests.swift
//  VTFrameProTests
//
//  统一错误域（AppError）测试。
//  覆盖规则：ARCHITECTURE.md §8.2（NSError domain + code + 中文文案 + recoverySuggestion + 弹窗策略）。
//

import Foundation
import XCTest
@testable import VTFramePro

final class AppErrorTests: XCTestCase {

    // MARK: - NSError 桥接（§8.2）

    /// 域常量与文档一致。
    func testErrorDomain_isComVtframeproError() {
        XCTAssertEqual(AppError.errorDomain, "com.vtframepro.error")
    }

    /// 各 case 的 errorCode 与注释编号 1:1 匹配。
    func testErrorCodes_matchArchSpec() {
        XCTAssertEqual(AppError.permissionDenied(.camera).errorCode, 1001)
        XCTAssertEqual(AppError.engineUnsupported(detail: "x").errorCode, 2001)
        XCTAssertEqual(AppError.modelDownloadFailed(underlying: "x").errorCode, 2002)
        XCTAssertEqual(AppError.modelValidationFailed(reasons: ["x"]).errorCode, 2003)
        XCTAssertEqual(AppError.noUsableEngine(capability: .frameInterpolation).errorCode, 2004)
        XCTAssertEqual(AppError.inferenceFailed(underlying: "x").errorCode, 2005)
        XCTAssertEqual(AppError.ioFailed(underlying: "x").errorCode, 4001)
        XCTAssertEqual(AppError.outOfMemory.errorCode, 4002)
        XCTAssertEqual(AppError.cancelled.errorCode, 4003)
    }

    /// NSError 桥接：domain + userInfo[NSLocalizedDescriptionKey]。
    func testNSErrorBridge_containsDomainAndDescription() {
        let underlying = AppError.engineUnsupported(detail: "A17 Pro 以下")
        let nsError = underlying as NSError
        XCTAssertEqual(nsError.domain, AppError.errorDomain)
        XCTAssertEqual(nsError.code, 2001)
        // LocalizedError.errorDescription 应注入 NSLocalizedDescriptionKey。
        XCTAssertNotNil(nsError.userInfo[NSLocalizedDescriptionKey])
        XCTAssertTrue(
            (nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? "")
                .contains("A17 Pro 以下")
        )
    }

    // MARK: - errorDescription（简体中文文案，§8.1）

    /// 权限错误：含权限种类中文名。
    func testErrorDescription_permissionDenied_containsKind() {
        let text = AppError.permissionDenied(.camera).errorDescription
        XCTAssertEqual(text, "摄像头权限未开启")
    }

    /// 引擎不支持：含 detail。
    func testErrorDescription_engineUnsupported_includesDetail() {
        let text = AppError.engineUnsupported(detail: "iOS 26+ 需要").errorDescription
        XCTAssertTrue(text?.contains("iOS 26+ 需要") == true)
    }

    /// 张量校验失败：reasons 多行拼接。
    func testErrorDescription_modelValidationFailed_joinsReasons() {
        let reasons = ["输入张量数应为 2", "批次须为 1", "输出 H/W 非整数倍"]
        let text = AppError.modelValidationFailed(reasons: reasons).errorDescription
        XCTAssertNotNil(text)
        for r in reasons {
            XCTAssertTrue(text!.contains(r), "应包含 reason: \(r)")
        }
        XCTAssertTrue(text!.contains("\n"), "reasons 之间应换行分隔")
    }

    /// 无可用引擎：含能力中文名。
    func testErrorDescription_noUsableEngine_usesCapabilityName() {
        XCTAssertEqual(
            AppError.noUsableEngine(capability: .frameInterpolation).errorDescription,
            "没有可用的补帧引擎"
        )
        XCTAssertEqual(
            AppError.noUsableEngine(capability: .superResolution).errorDescription,
            "没有可用的超分引擎"
        )
    }

    /// 取消：非空文案（前端可能按需使用）。
    func testErrorDescription_cancelled_isNonEmpty() {
        XCTAssertEqual(AppError.cancelled.errorDescription, "已取消")
    }

    /// OOM：含「内存不足」语义。
    func testErrorDescription_outOfMemory_saysMemory() {
        XCTAssertTrue(
            AppError.outOfMemory.errorDescription?.contains("内存不足") == true
        )
    }

    // MARK: - recoverySuggestion（动作引导，§8.2）

    /// 取消错误无 recoverySuggestion（正常状态机，不走引导）。
    func testRecoverySuggestion_cancelled_isNil() {
        XCTAssertNil(AppError.cancelled.recoverySuggestion)
    }

    /// 权限错误：含「设置」字样。
    func testRecoverySuggestion_permissionDenied_mentionsSettings() {
        let text = AppError.permissionDenied(.camera).recoverySuggestion ?? ""
        XCTAssertTrue(text.contains("设置"))
    }

    /// 引擎不支持：引导导入模型（§2.3 R-31 替代方案）。
    func testRecoverySuggestion_engineUnsupported_mentionsImport() {
        let text = AppError.engineUnsupported(detail: "").recoverySuggestion ?? ""
        XCTAssertTrue(text.contains("导入") || text.contains("模型"))
    }

    // MARK: - shouldPresentAlert（取消与下载三态不弹窗，§8.2）

    /// 取消：不应弹窗。
    func testShouldPresentAlert_cancelled_isFalse() {
        XCTAssertFalse(AppError.cancelled.shouldPresentAlert)
    }

    /// 其它错误：均应弹窗。
    func testShouldPresentAlert_others_areTrue() {
        XCTAssertTrue(AppError.permissionDenied(.camera).shouldPresentAlert)
        XCTAssertTrue(AppError.engineUnsupported(detail: "x").shouldPresentAlert)
        XCTAssertTrue(AppError.modelDownloadFailed(underlying: "x").shouldPresentAlert)
        XCTAssertTrue(AppError.modelValidationFailed(reasons: ["x"]).shouldPresentAlert)
        XCTAssertTrue(AppError.noUsableEngine(capability: .frameInterpolation).shouldPresentAlert)
        XCTAssertTrue(AppError.inferenceFailed(underlying: "x").shouldPresentAlert)
        XCTAssertTrue(AppError.ioFailed(underlying: "x").shouldPresentAlert)
        XCTAssertTrue(AppError.outOfMemory.shouldPresentAlert)
    }

    // MARK: - PermissionKind 文案

    func testPermissionKind_displayName() {
        XCTAssertEqual(PermissionKind.camera.displayName, "摄像头")
        XCTAssertEqual(PermissionKind.photoLibrary.displayName, "照片库")
        XCTAssertEqual(PermissionKind.photoAddOnly.displayName, "照片库保存")
    }

    // MARK: - Equatable（§8.1：状态枚举用等值判等）

    func testEquality_byCase() {
        XCTAssertEqual(
            AppError.permissionDenied(.camera),
            AppError.permissionDenied(.camera)
        )
        XCTAssertNotEqual(
            AppError.permissionDenied(.camera),
            AppError.permissionDenied(.photoAddOnly)
        )
        XCTAssertEqual(
            AppError.modelValidationFailed(reasons: ["a"]),
            AppError.modelValidationFailed(reasons: ["a"])
        )
    }
}