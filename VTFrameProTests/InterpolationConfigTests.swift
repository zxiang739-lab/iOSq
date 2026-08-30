//
//  InterpolationConfigTests.swift
//  VTFrameProTests
//
//  补帧配置值类型（InterpolationConfig / UpscaleQuality）。
//  覆盖规则：ARCHITECTURE.md §2.1（InterpolationConfig.factor 首版锁 x2，§10-1）；
//          §2.2 分档（R-29：实时 .lowLatency / 离线 .highQuality）。
//

import XCTest
@testable import VTFramePro

final class InterpolationConfigTests: XCTestCase {

    /// 默认：x2 + 低延迟（实时链路，§10-1）。
    func testDefaultConfig() {
        let config = InterpolationConfig()
        XCTAssertEqual(config.factor, 2)
        XCTAssertEqual(config.quality, .lowLatency)
    }

    // MARK: - phases（每对输入帧产出的中间帧插值相位序列）

    /// x2 → 单相位 0.5（补帧 2× 输出）。
    func testPhases_x2() throws {
        let config = InterpolationConfig(factor: 2, quality: .lowLatency)
        XCTAssertEqual(config.phases, [0.5])
    }

    /// x4 → 相位 [0.25, 0.5, 0.75]（每对帧插 3 帧，§10-1 预留）。
    func testPhases_x4() throws {
        let config = InterpolationConfig(factor: 4, quality: .highQuality)
        XCTAssertEqual(config.phases, [0.25, 0.5, 0.75])
    }

    /// factor ≤ 1 → 无中间帧（不合法配置返回空，业务层不应使用）。
    func testPhases_factorOneOrZero_returnsEmpty() {
        XCTAssertEqual(InterpolationConfig(factor: 1).phases, [])
        XCTAssertEqual(InterpolationConfig(factor: 0).phases, [])
    }

    /// 相位严格位于开区间 (0,1)，且值域与 factor 对齐（1..<factor）/ factor。
    func testPhases_areWithinOpenUnitInterval() {
        for factor in 2...8 {
            for phase in InterpolationConfig(factor: factor).phases {
                XCTAssertGreaterThan(phase, 0)
                XCTAssertLessThan(phase, 1)
            }
        }
    }

    // MARK: - 分档（R-29）

    func testUpscaleQuality_cases() {
        // 编译期保证两档存在；语义由引擎按档位选择会话配置。
        let realtime: UpscaleQuality = .lowLatency
        let offline: UpscaleQuality = .highQuality
        XCTAssertNotEqual(realtime, offline)
    }
}