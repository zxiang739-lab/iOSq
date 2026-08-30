//
//  ProcessingSettingsTests.swift
//  VTFrameProTests
//
//  默认处理参数 + UserDefaults 持久化测试（ProcessingSettings / RealtimeQualityTier）。
//  覆盖规则：PRD R-21（处理参数设置）；ARCHITECTURE.md §10-1（实时补帧锁 x2）。
//

import Foundation
import XCTest
@testable import VTFramePro

final class ProcessingSettingsTests: XCTestCase {

    /// 每个测试独立的 UserDefaults 域，避免污染 .standard（测试隔离）。
    private func makeSuiteDefaults() -> UserDefaults {
        let name = "com.vtframepro.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - 默认值

    /// 默认值：离线补帧 x2、实时画质均衡（§10-1 / R-21）。
    func testDefault_value() {
        let settings = ProcessingSettings.default
        XCTAssertEqual(settings.interpolationFactor, 2)
        XCTAssertEqual(settings.realtimeQualityTier, .balanced)
    }

    /// 实时链路补帧倍率锁死 x2（架构拍板常量，§10-1）。
    func testRealtimeInterpolationFactor_lockedTo2() {
        XCTAssertEqual(ProcessingSettings.realtimeInterpolationFactor, 2)
    }

    /// 空 UserDefaults 回落到 .default。
    func testLoad_emptyDefaults_returnsDefault() {
        let defaults = makeSuiteDefaults()
        XCTAssertEqual(ProcessingSettings.load(defaults: defaults), .default)
    }

    // MARK: - 持久化 round-trip（Codable → JSON → UserDefaults）

    /// 修改后保存 → 再 load 读取到一致值。
    func testSaveLoad_roundTrip_persistsChanges() {
        let defaults = makeSuiteDefaults()
        var settings = ProcessingSettings.default
        settings.interpolationFactor = 4      // x4 字段预留（R-21 说明）
        settings.realtimeQualityTier = .quality

        settings.save(defaults: defaults)
        let loaded = ProcessingSettings.load(defaults: defaults)
        XCTAssertEqual(loaded.interpolationFactor, 4)
        XCTAssertEqual(loaded.realtimeQualityTier, .quality)
    }

    /// 多次保存互相覆盖，取最后一次（UserDefaults 单键事实源）。
    func testSave_overwritesPrevious() {
        let defaults = makeSuiteDefaults()
        var first = ProcessingSettings.default
        first.realtimeQualityTier = .performance
        first.save(defaults: defaults)

        var second = ProcessingSettings.default
        second.realtimeQualityTier = .quality
        second.save(defaults: defaults)

        XCTAssertEqual(ProcessingSettings.load(defaults: defaults).realtimeQualityTier, .quality)
    }

    /// 损坏数据（非法 JSON）回落默认，不崩溃（§8.1 持久化健壮性）。
    func testLoad_corruptedData_returnsDefault() {
        let defaults = makeSuiteDefaults()
        defaults.set(Data("not-json".utf8), forKey: "com.vtframepro.settings")
        XCTAssertEqual(ProcessingSettings.load(defaults: defaults), .default)
    }

    /// 跨默认实例加载不同持久化域互不影响。
    func testLoad_suiteIsolation() {
        let defaultsA = makeSuiteDefaults()
        let defaultsB = makeSuiteDefaults()
        var custom = ProcessingSettings.default
        custom.realtimeQualityTier = .performance
        custom.save(defaults: defaultsA)
        XCTAssertEqual(ProcessingSettings.load(defaults: defaultsA).realtimeQualityTier, .performance)
        XCTAssertEqual(ProcessingSettings.load(defaults: defaultsB).realtimeQualityTier, .balanced)
    }

    // MARK: - RealtimeQualityTier

    func testQualityTier_allCases_andDisplayName() {
        XCTAssertEqual(RealtimeQualityTier.allCases.count, 3)
        XCTAssertEqual(RealtimeQualityTier.performance.displayName, "性能优先")
        XCTAssertEqual(RealtimeQualityTier.balanced.displayName, "均衡")
        XCTAssertEqual(RealtimeQualityTier.quality.displayName, "画质优先")
    }

    // MARK: - 值语义

    func testSettings_equatable() {
        XCTAssertEqual(ProcessingSettings.default, ProcessingSettings.default)
        var other = ProcessingSettings.default
        other.interpolationFactor = 4
        XCTAssertNotEqual(ProcessingSettings.default, other)
    }
}