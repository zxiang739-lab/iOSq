//
//  PixelBufferPool.swift
//  VTFramePro
//
//  CVPixelBuffer 池化复用（L3 媒体服务层）。
//  对应 ARCHITECTURE.md §3.1 零拷贝策略与 §9.3 OOM 防线（每规格上限 6，告警 drain）。
//

import Foundation
import CoreVideo
import OSLog

/// CVPixelBuffer 池化复用器。
///
/// 策略：
/// - 按「宽×高」分桶维护 `CVPixelBufferPool`，每规格在飞上限 6 个（§9.3）；
/// - 像素格式统一 `kCVPixelFormatType_32BGRA`（与 VT 会话/张量约定一致，§3.3-1）；
/// - 池耗尽时不阻塞：回落独立分配（避免实时链路卡死），并记 notice 日志；
/// - 内存告警时 `drain()` 冲刷全部池（buffer 用毕归还后系统回收）。
///
/// 线程：NSLock 保护，可在任意线程调用（采集队列/推理域/写入域共用）。
final class PixelBufferPool: @unchecked Sendable {

    /// 每规格在飞上限（§9.3）。
    static let maxBuffersPerSpec: Int = 6

    private let lock = NSLock()
    /// 分桶池：key = "宽x高"。
    private var pools: [String: CVPixelBufferPool] = [:]
    private let logger = Logger(subsystem: "com.vtframepro", category: "media")

    init() {}

    // MARK: - 分配

    /// 分配指定尺寸的 BGRA buffer（优先池化复用）。
    ///
    /// - Parameters:
    ///   - width: 像素宽。
    ///   - height: 像素高。
    /// - Returns: 可用 buffer（调用方负责释放引用，归还后即回池）。
    /// - Throws: `AppError.outOfMemory`（池与独立分配均失败）。
    func acquire(width: Int, height: Int) throws -> CVPixelBuffer {
        let pool = try poolFor(width: width, height: height)

        // 带阈值的非阻塞分配：超过在飞上限直接返回失败而非等待（实时链路不阻塞）。
        var pixelBuffer: CVPixelBuffer?
        let auxAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey: Self.maxBuffersPerSpec
        ] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            nil, pool, auxAttributes, &pixelBuffer)

        if status == kCVReturnSuccess, let pixelBuffer {
            return pixelBuffer
        }

        // 池耗尽回落：独立分配（不阻塞链路），由调用方释放后系统回收。
        logger.notice("缓冲池 \(width)×\(height) 耗尽（status=\(status)），回落独立分配")
        var fallback: CVPixelBuffer?
        let fallbackStatus = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            Self.bufferAttributes(width: width, height: height) as CFDictionary,
            &fallback)
        guard fallbackStatus == kCVReturnSuccess, let fallback else {
            throw AppError.outOfMemory
        }
        return fallback
    }

    // MARK: - 冲刷

    /// 内存告警时冲刷全部池（didReceiveMemoryWarning / DispatchSourceMemoryPressure，§9.3）。
    func drain() {
        let currentPools = lock.withLock { () -> [CVPixelBufferPool] in
            let values = Array(pools.values)
            pools.removeAll()
            return values
        }
        for pool in currentPools {
            CVPixelBufferPoolFlush(pool, [])
        }
        logger.notice("缓冲池已冲刷（内存告警响应）")
    }

    // MARK: - 私有：池创建

    /// 取/建指定尺寸的池。
    private func poolFor(width: Int, height: Int) throws -> CVPixelBufferPool {
        let key = "\(width)x\(height)"
        if let cached = lock.withLock({ pools[key] }) {
            return cached
        }
        let poolAttributes = [
            kCVPixelBufferPoolMinimumBufferCountKey: 2
        ] as CFDictionary
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil, poolAttributes,
            Self.bufferAttributes(width: width, height: height) as CFDictionary,
            &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw AppError.outOfMemory
        }
        lock.withLock { pools[key] = pool }
        return pool
    }

    /// buffer 属性：32BGRA + Metal 兼容（CVMetalTextureCache 直建纹理，零拷贝前提）。
    private static func bufferAttributes(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
    }
}
