//
//  EngineRegistryTests.swift
//  VTFrameProTests
//
//  引擎注册 / 能力查询 / 切换 / 降级决策测试。
//  覆盖规则：ARCHITECTURE.md §2.3（R-20 切换、R-31 降级决策顺序①→②→③）。
//

import Foundation
import XCTest
@testable import VTFramePro

/// EngineRegistry 为 @MainActor，测试类整体主线程隔离（Swift 6 严格并发，§8.4）。
@MainActor
final class EngineRegistryTests: XCTestCase {

    // MARK: - 注册 / 反注册（§2.3）

    /// 注册后引擎进入列表；首个声明该能力的引擎自动成为生效位（默认 active）。
    func testRegister_addsAndAutoActivatesFirst() {
        let registry = EngineRegistry()
        let sr = MockAIEngine(engineID: "coreml-sr-1",
                              capabilities: [.superResolution],
                              state: .ready)
        registry.register(sr)
        XCTAssertEqual(registry.engines.count, 1)
        XCTAssertTrue(registry.activeEngine[.superResolution]?.engineID == "coreml-sr-1")
        XCTAssertNil(registry.activeEngine[.frameInterpolation])
    }

    /// 同 engineID 重复注册 → 幂等替换（不产生重复项）。
    func testRegister_sameID_replaces() {
        let registry = EngineRegistry()
        let vt1 = MockAIEngine(engineID: "system-vt")
        let vt2 = MockAIEngine(engineID: "system-vt", displayName: "VT-2")
        registry.register(vt1)
        registry.register(vt2)
        XCTAssertEqual(registry.engines.count, 1)
        XCTAssertTrue(registry.engines.first?.displayName == "VT-2")
    }

    /// 反注册：从列表移除，并摘除其占据的生效位（R-19 删除模型）。
    func testUnregister_removesEngineAndActiveSlot() {
        let registry = EngineRegistry()
        let sr = MockAIEngine(engineID: "coreml-sr-1",
                              capabilities: [.superResolution],
                              state: .ready)
        registry.register(sr)
        fixtureRegisterVT(registry)
        XCTAssertNotNil(registry.activeEngine[.superResolution])

        registry.unregister(engineID: "coreml-sr-1")
        XCTAssertTrue(registry.engine(withID: "coreml-sr-1") == nil)
        // active 位应回落到唯一仍声明超分的引擎（VT）——由下次 resolve 兜底，
        // 此处断言已摘除对应 slot（若 VT 也已注册则不再指向被删引擎）。
        XCTAssertFalse(registry.activeEngine[.superResolution]?.engineID == "coreml-sr-1")
    }

    // MARK: - engine(withID:) 查询

    func testEngineWithID_returnsRegistered() {
        let registry = EngineRegistry()
        let vt = MockAIEngine(engineID: "system-vt")
        registry.register(vt)
        XCTAssertTrue(registry.engine(withID: "system-vt")?.engineID == "system-vt")
        XCTAssertNil(registry.engine(withID: "missing"))
    }

    // MARK: - setActive（R-20 切换，校验 capabilities）

    /// 目标引擎声明该能力 → 成功并成为 active。
    func testSetActive_success() throws {
        let registry = EngineRegistry()
        fixtureRegisterVT(registry)
        let sr = MockAIEngine(engineID: "coreml-sr-1",
                              capabilities: [.superResolution],
                              state: .ready)
        registry.register(sr)

        try registry.setActive(sr, for: .superResolution)
        XCTAssertTrue(registry.activeEngine[.superResolution]?.engineID == "coreml-sr-1")
        XCTAssertNil(registry.fallbackNotice, "手动切换成功不应产生降级横幅")
    }

    /// 目标引擎未声明该能力 → 抛 AppError.engineUnsupported（R-20 校验）。
    func testSetActive_throwsWhenCapabilityMissing() {
        let registry = EngineRegistry()
        let srOnly = MockAIEngine(engineID: "coreml-sr-1",
                                  capabilities: [.superResolution],
                                  state: .ready)
        registry.register(srOnly)
        XCTAssertThrowsError(try registry.setActive(srOnly, for: .frameInterpolation)) { error in
            guard case AppError.engineUnsupported = error else {
                return XCTFail("期望 engineUnsupported，实际 \(error)")
            }
        }
    }

    // MARK: - 降级决策 resolveUsableEngine（R-31 顺序①→②→③）

    /// 决策①：active 引擎可用 → 直接用之，无横幅。
    func testResolve_activeUsable_preferred() {
        let registry = EngineRegistry()
        let vt = MockAIEngine(engineID: "system-vt", state: .ready)
        registry.register(vt)

        let resolved = registry.resolveUsableEngine(for: .frameInterpolation)
        XCTAssertTrue(resolved?.engineID == "system-vt")
        XCTAssertNil(registry.fallbackNotice)
    }

    /// 决策②：active 不可用 + VT 可用 → 回落 VT（优先系统引擎），并写降级横幅。
    func testResolve_fallbackToVT_whenCoreMLUnavailable() {
        let registry = EngineRegistry()
        // 注册顺序：先 CoreML（成为 active），但其状态不可用。
        let coreML = MockAIEngine(engineID: "coreml-a",
                                  kind: .coreMLImported,
                                  capabilities: [.superResolution],
                                  state: .modelNotInstalled)
        registry.register(coreML)
        // 后 VT（active 仍为 coreML，因为 slot 已占）。
        let vt = MockAIEngine(engineID: "system-vt",
                              capabilities: [.superResolution],
                              state: .ready)
        registry.register(vt)

        let resolved = registry.resolveUsableEngine(for: .superResolution)
        XCTAssertTrue(resolved?.engineID == "system-vt", "应为回落 VT")
        XCTAssertNotNil(registry.fallbackNotice)
        XCTAssertTrue(registry.activeEngine[.superResolution]?.engineID == "system-vt",
                      "回落应更新 active 位")
    }

    /// 决策②：active(VT) 不可用 → 回落第一个就绪 CoreML 引擎。
    func testResolve_fallbackToCoreML_whenVTUnsupported() {
        let registry = EngineRegistry()
        let vt = MockAIEngine(engineID: "system-vt",
                              state: .unsupported(reason: "设备不支持"))
        registry.register(vt)
        let coreML = MockAIEngine(engineID: "coreml-b",
                                  kind: .coreMLImported,
                                  capabilities: [.frameInterpolation],
                                  state: .ready)
        registry.register(coreML)

        let resolved = registry.resolveUsableEngine(for: .frameInterpolation)
        XCTAssertTrue(resolved?.engineID == "coreml-b")
        XCTAssertNotNil(registry.fallbackNotice)
    }

    /// 决策③：均不可用 → nil，入口置灰（R-31 最后一步）。
    func testResolve_noUsableEngine_returnsNil() {
        let registry = EngineRegistry()
        let vt = MockAIEngine(engineID: "system-vt",
                              state: .unsupported(reason: "设备不支持"))
        registry.register(vt)
        let coreML = MockAIEngine(engineID: "coreml-c",
                                  kind: .coreMLImported,
                                  capabilities: [.frameInterpolation],
                                  state: .downloadFailed(message: "x"))
        registry.register(coreML)

        XCTAssertNil(registry.resolveUsableEngine(for: .frameInterpolation))
    }

    /// 决策③衍生：无任何声明能力的引擎 → nil。
    func testResolve_noDeclaringEngine_returnsNil() {
        let registry = EngineRegistry()
        let onlySR = MockAIEngine(engineID: "coreml-only-sr",
                                  capabilities: [.superResolution],
                                  state: .ready)
        registry.register(onlySR)
        XCTAssertNil(registry.resolveUsableEngine(for: .frameInterpolation))
    }

    // MARK: - hasEngine / unavailableReason（HomeViewModel 置灰文案辅助，R-28/R-31）

    func testHasEngine_declaring() {
        let registry = EngineRegistry()
        let sr = MockAIEngine(engineID: "coreml-sr", capabilities: [.superResolution])
        registry.register(sr)
        XCTAssertTrue(registry.hasEngine(declaring: .superResolution))
        XCTAssertFalse(registry.hasEngine(declaring: .frameInterpolation))
    }

    /// 无声明引擎 → 统一置灰文案；有引擎不可用 → 聚合各引擎状态原因。
    func testUnavailableReason_aggregates() {
        let registry = EngineRegistry()
        XCTAssertEqual(registry.unavailableReason(for: .frameInterpolation),
                       "设备不支持系统引擎，且未导入自定义模型")

        let vt = MockAIEngine(engineID: "system-vt", displayName: "系统 VT 引擎",
                              state: .unsupported(reason: "A17 Pro 以下"))
        registry.register(vt)
        let reason = registry.unavailableReason(for: .frameInterpolation)
        XCTAssertTrue(reason.contains("系统 VT 引擎"))
        XCTAssertTrue(reason.contains("不支持"))
    }

    // MARK: - refreshStates（启动/回前台重检，§3.3-3）

    /// refreshStates 对每个引擎的每个能力调用 prepare（幂等可重试，§10-2）。
    func testRefreshStates_triggersPreparePerCapability() async {
        let registry = EngineRegistry()
        let vt = MockAIEngine(engineID: "system-vt") // 双能力
        registry.register(vt)
        let coreML = MockAIEngine(engineID: "coreml-d",
                                  kind: .coreMLImported,
                                  capabilities: [.superResolution])
        registry.register(coreML)

        await registry.refreshStates()
        // 双能力 VT × 1 + 单能力 CoreML × 1。
        XCTAssertEqual(vt.prepareCallCount, 2)
        XCTAssertEqual(coreML.prepareCallCount, 1)
    }

    /// refreshStates 单引擎失败不影响其余（try? 吞错，§2.3）。
    func testRefreshStates_singleFailureDoesNotStopOthers() async {
        let registry = EngineRegistry()
        let failing = MockAIEngine(engineID: "coreml-fail",
                                   kind: .coreMLImported,
                                   capabilities: [.superResolution])
        failing.setPrepareFailure(.engineUnsupported(detail: "模拟失败"))
        registry.register(failing)
        let vt = MockAIEngine(engineID: "system-vt", capabilities: [.frameInterpolation])
        registry.register(vt)

        await registry.refreshStates()
        XCTAssertEqual(vt.prepareCallCount, 1, "其余引擎应照常 prepare")
    }

    // MARK: - 帮助

    /// 注册一台就绪 VT 引擎（双能力）。
    @discardableResult
    private func fixtureRegisterVT(_ registry: EngineRegistry) -> MockAIEngine {
        let vt = MockAIEngine(engineID: "system-vt", state: .ready)
        registry.register(vt)
        return vt
    }
}