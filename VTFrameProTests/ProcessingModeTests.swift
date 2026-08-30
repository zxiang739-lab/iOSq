//
//  ProcessingModeTests.swift
//  VTFrameProTests
//
//  5 种业务模式枚举测试。
//  覆盖规则：PRD R-01~R-05；PRD §3.2 页面入口；ARCHITECTURE.md §1.1（链路类型/能力映射）。
//

import XCTest
@testable import VTFramePro

final class ProcessingModeTests: XCTestCase {

    /// 恰好 5 种模式（PRD §3.2 主界面 5 入口）。
    func testAllCases_hasExactlyFiveModes() {
        XCTAssertEqual(ProcessingMode.allCases.count, 5)
        XCTAssertEqual(Set(ProcessingMode.allCases.map(\.rawValue)).count, 5)
    }

    // MARK: - 链路类型（实时 / 离线）

    /// 实时三种：实时补帧 / 超分 / 串联。
    func testIsRealtime_maps() {
        XCTAssertTrue(ProcessingMode.realtimeInterpolation.isRealtime)
        XCTAssertTrue(ProcessingMode.realtimeSuperResolution.isRealtime)
        XCTAssertTrue(ProcessingMode.realtimeCombined.isRealtime)
        XCTAssertFalse(ProcessingMode.offlineInterpolation.isRealtime)
        XCTAssertFalse(ProcessingMode.offlineSuperResolution.isRealtime)
    }

    // MARK: - 所需能力（R-26 / R-31 可用性判定基准）

    /// 补帧两类模式 → 仅需 .frameInterpolation。
    func testRequiredCapabilities_interpolationModes() {
        XCTAssertEqual(ProcessingMode.realtimeInterpolation.requiredCapabilities,
                       [.frameInterpolation])
        XCTAssertEqual(ProcessingMode.offlineInterpolation.requiredCapabilities,
                       [.frameInterpolation])
    }

    /// 超分两类模式 → 仅需 .superResolution。
    func testRequiredCapabilities_superResolutionModes() {
        XCTAssertEqual(ProcessingMode.realtimeSuperResolution.requiredCapabilities,
                       [.superResolution])
        XCTAssertEqual(ProcessingMode.offlineSuperResolution.requiredCapabilities,
                       [.superResolution])
    }

    /// 实时串联 → 需补帧+超分双能力（单引擎串联约定，§3.1-①）。
    func testRequiredCapabilities_combined_needsBoth() {
        XCTAssertEqual(ProcessingMode.realtimeCombined.requiredCapabilities,
                       [.frameInterpolation, .superResolution])
    }

    // MARK: - 输出节拍（§3.1 DisplayLink 2× 节拍）

    /// 补帧/串联输出 2× 节拍；其余 1×。
    func testOutputCadenceMultiplier() {
        XCTAssertEqual(ProcessingMode.realtimeInterpolation.outputCadenceMultiplier, 2)
        XCTAssertEqual(ProcessingMode.realtimeCombined.outputCadenceMultiplier, 2)
        XCTAssertEqual(ProcessingMode.realtimeSuperResolution.outputCadenceMultiplier, 1)
        XCTAssertEqual(ProcessingMode.offlineInterpolation.outputCadenceMultiplier, 1)
        XCTAssertEqual(ProcessingMode.offlineSuperResolution.outputCadenceMultiplier, 1)
    }

    // MARK: - 串联判定

    func testIsChained_onlyCombined() {
        XCTAssertTrue(ProcessingMode.realtimeCombined.isChained)
        XCTAssertFalse(ProcessingMode.realtimeInterpolation.isChained)
        XCTAssertFalse(ProcessingMode.offlineSuperResolution.isChained)
    }

    // MARK: - 文案与标识（§8.1 文案集中）

    func testDisplayName_allNonEmptyChinese() {
        for mode in ProcessingMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode.rawValue) displayName 非空")
            XCTAssertFalse(mode.subtitle.isEmpty, "\(mode.rawValue) subtitle 非空")
        }
    }

    func testDisplayName_expectedValues() {
        XCTAssertEqual(ProcessingMode.realtimeInterpolation.displayName, "实时补帧")
        XCTAssertEqual(ProcessingMode.realtimeSuperResolution.displayName, "实时超分")
        XCTAssertEqual(ProcessingMode.realtimeCombined.displayName, "实时补帧+超分")
        XCTAssertEqual(ProcessingMode.offlineInterpolation.displayName, "离线补帧")
        XCTAssertEqual(ProcessingMode.offlineSuperResolution.displayName, "离线超分")
    }

    /// ID = rawValue（Identifiable 契约）。
    func testIdentifiable_idIsRawValue() {
        for mode in ProcessingMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    /// 离线模式仅两种（R-04/R-05；无离线串联，PRD「明确不做」）。
    func testOfflineModes_areOnlyInterpolationAndSuperResolution() {
        XCTAssertEqual(Set(ProcessingMode.allCases.filter { !$0.isRealtime }),
                       [.offlineInterpolation, .offlineSuperResolution])
    }
}