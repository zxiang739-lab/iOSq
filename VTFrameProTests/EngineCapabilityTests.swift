//
//  EngineCapabilityTests.swift
//  VTFrameProTests
//
//  引擎能力 / 种类 / 状态枚举测试。
//  覆盖规则：ARCHITECTURE.md §2.1（EngineCapability / EngineKind / EngineState + isUsable）。
//

import XCTest
@testable import VTFramePro

final class EngineCapabilityTests: XCTestCase {

    // MARK: - EngineCapability

    func testCapability_displayName() {
        XCTAssertEqual(EngineCapability.frameInterpolation.displayName, "补帧")
        XCTAssertEqual(EngineCapability.superResolution.displayName, "超分")
    }

    /// CaseIterable 全量两个能力（首版全部能力）。
    func testCapability_allCases() {
        XCTAssertEqual(EngineCapability.allCases.count, 2)
        XCTAssertTrue(EngineCapability.allCases.contains(.frameInterpolation))
        XCTAssertTrue(EngineCapability.allCases.contains(.superResolution))
    }

    // MARK: - EngineKind

    func testEngineKind_displayName() {
        XCTAssertEqual(EngineKind.systemVT.displayName, "系统 VT 引擎")
        XCTAssertEqual(EngineKind.coreMLImported.displayName, "导入模型")
    }

    // MARK: - EngineState.isUsable（§2.1 唯一可用态 = .ready）

    func testIsUsable_onlyReady() {
        XCTAssertTrue(EngineState.ready.isUsable)
        XCTAssertFalse(EngineState.checking.isUsable)
        XCTAssertFalse(EngineState.unsupported(reason: "").isUsable)
        XCTAssertFalse(EngineState.modelNotInstalled.isUsable)
        XCTAssertFalse(EngineState.modelDownloading(progress: 0.5).isUsable)
        XCTAssertFalse(EngineState.downloadFailed(message: "").isUsable)
    }

    // MARK: - EngineState.displayName（文案集中，§8.1）

    func testDisplayName_basicStates() {
        XCTAssertEqual(EngineState.checking.displayName, "检测中…")
        XCTAssertEqual(EngineState.ready.displayName, "就绪")
        XCTAssertEqual(EngineState.modelNotInstalled.displayName, "未导入模型")
    }

    func testDisplayName_associatedValuesIncluded() {
        XCTAssertEqual(EngineState.unsupported(reason: "A17 Pro 以下").displayName,
                       "不支持：A17 Pro 以下")
        XCTAssertEqual(
            EngineState.downloadFailed(message: "网络超时").displayName,
            "下载失败：网络超时"
        )
    }

    /// 下载进度百分比格式（progress ∈ [0,1] → 0%~100%）。
    func testDisplayName_modelDownloading_formatsProgress() {
        XCTAssertEqual(EngineState.modelDownloading(progress: 0).displayName, "模型下载中 0%")
        XCTAssertEqual(EngineState.modelDownloading(progress: 0.5).displayName, "模型下载中 50%")
        XCTAssertEqual(EngineState.modelDownloading(progress: 1).displayName, "模型下载中 100%")
    }

    // MARK: - Equatable（§8.1：ViewModel 状态比对用等值）

    func testStateEquality() {
        XCTAssertEqual(EngineState.downloadFailed(message: "x"),
                       EngineState.downloadFailed(message: "x"))
        XCTAssertNotEqual(EngineState.downloadFailed(message: "x"),
                          EngineState.downloadFailed(message: "y"))
        XCTAssertNotEqual(EngineState.modelDownloading(progress: 0.3),
                          EngineState.modelDownloading(progress: 0.4))
    }
}