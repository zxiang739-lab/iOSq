//
//  ProcessingCancelTokenTests.swift
//  VTFrameProTests
//
//  离线任务取消令牌测试（ProcessingCancelToken）。
//  覆盖规则：ARCHITECTURE.md §3.2（取消传播：帧循环检查点轮询令牌）。
//

import XCTest
@testable import VTFramePro

final class ProcessingCancelTokenTests: XCTestCase {

    /// 初始未取消。
    func testInitialState_notCancelled() {
        let token = ProcessingCancelToken()
        XCTAssertFalse(token.isCancelled)
    }

    /// cancel 后 isCancelled 为 true。
    func testCancel_flipsFlag() {
        let token = ProcessingCancelToken()
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }

    /// cancel 幂等。
    func testCancel_idempotent() {
        let token = ProcessingCancelToken()
        token.cancel()
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }
}