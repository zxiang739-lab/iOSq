//
//  PixelBufferPoolTests.swift
//  VTFrameProTests
//
//  CVPixelBuffer 池化复用测试。
//  覆盖规则：ARCHITECTURE.md §3.1 零拷贝策略与 §9.3 OOM 防线（每规格上限 6、drain）。
//
//  说明：本测试创建真实 CVPixelBufferPool/CVPixelBuffer（CoreVideo，iOS 单元测试可用）；
//  模拟器/真机均可运行。若测试主机不支持 Metal 兼容属性（极少），acquire 仍应成功。
//

import CoreVideo
import XCTest
@testable import VTFramePro

final class PixelBufferPoolTests: XCTestCase {

    /// 每规格上限常量符合架构约定（§9.3）。
    func testMaxBuffersPerSpec_isSix() {
        XCTAssertEqual(PixelBufferPool.maxBuffersPerSpec, 6)
    }

    /// acquire 返回指定尺寸的 32BGRA buffer。
    func testAcquire_createsBufferWithRequestedSize() throws {
        let pool = PixelBufferPool()
        let buffer = try pool.acquire(width: 1280, height: 720)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 720)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
    }

    /// 同规格连续 acquire 6 个均在飞（阈值内）；第 7 个回落独立分配仍返回 buffer。
    func testAcquire_upToAndBeyondThreshold() throws {
        let pool = PixelBufferPool()
        var held: [CVPixelBuffer] = []
        // 阈值内（≤6）。
        for _ in 0..<PixelBufferPool.maxBuffersPerSpec {
            held.append(try pool.acquire(width: 320, height: 240))
        }
        XCTAssertEqual(CVPixelBufferGetWidth(held[0]), 320)
        // 超出阈值：回落独立分配，不应抛错（实时链路不阻塞，§3.1）。
        let seventh = try pool.acquire(width: 320, height: 240)
        XCTAssertEqual(CVPixelBufferGetWidth(seventh), 320)
        // 释放后回池（held 出作用域回收）。
    }

    /// 不同规格分桶独立。
    func testAcquire_differentSpecsSeparateBuckets() throws {
        let pool = PixelBufferPool()
        let small = try pool.acquire(width: 100, height: 100)
        let large = try pool.acquire(width: 2000, height: 2000)
        XCTAssertEqual(CVPixelBufferGetWidth(small), 100)
        XCTAssertEqual(CVPixelBufferGetWidth(large), 2000)
    }

    /// drain 冲刷全部池后仍可继续 acquire（内存告警响应，§9.3）。
    func testDrain_thenAcquireStillWorks() throws {
        let pool = PixelBufferPool()
        _ = try pool.acquire(width: 640, height: 480)
        pool.drain()
        // 冲刷后新建池获取正常。
        let buffer = try pool.acquire(width: 640, height: 480)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 480)
    }

    /// drain 幂等（空池重复调用不崩溃）。
    func testDrain_idempotent() {
        let pool = PixelBufferPool()
        pool.drain()
        pool.drain()
    }

    /// 非法尺寸（0 或负数）抛出 outOfMemory？—— CoreVideo 对 0 尺寸视为创建失败，
    /// 实现吞掉并抛 .outOfMemory（§9.3 明确内存错误域）。
    func testAcquire_zeroSize_throws() {
        let pool = PixelBufferPool()
        XCTAssertThrowsError(try pool.acquire(width: 0, height: 100)) { error in
            guard case AppError.outOfMemory = error else {
                return XCTFail("期望 .outOfMemory，实际 \(error)")
            }
        }
    }
}