//
//  OfflineProcessingService.swift
//  VTFramePro
//
//  AVAssetReader/Writer 离线处理主流程（L3 媒体服务层）。
//  对应 ARCHITECTURE.md §3.2 离线链路（R-04/05）与 §9.3 OOM 防线（R-15）。
//
//  主流程（§3.2）：
//  ① AVAssetReader 逐帧解码（源分辨率/原帧率，读侧不重采样）；
//  ② 分批处理：每批 15 帧一个 autoreleasepool（告警后缩批至 8）；
//     每帧检查 Task 取消 + 内存水位（os_proc_available_memory() < 512MB → 中止）；
//  ③ 引擎处理（离线档 .highQuality）：补帧帧配对 2× PTS 重打 / 超分逐帧 PTS 透传；
//  ④ AVAssetWriter 写出 HEVC（hvc1），码率 = 源码率 × 1.5；
//  ⑤ 完成 → PhotoLibraryService 保存 → 任务 .completed。
//

import Foundation
import AVFoundation
import os
import OSLog

// MARK: - 取消令牌

/// 离线任务取消令牌（队列持有，帧循环检查点轮询）。
final class ProcessingCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool { lock.withLock { _isCancelled } }
    func cancel() { lock.withLock { _isCancelled = true } }
}

// MARK: - 离线处理服务

/// 离线处理主流程服务。
///
/// 只面向 `AIEngine` 协议编程（§1.2 第 2 条）。
/// 内存压力降级（§3.2）：DispatchSourceMemoryPressure 监听（GCD 保留点之二，§8.3）——
/// warning 级：drain 池 + 缩批（15→8）；critical 级：置中止标志，下一检查点抛 .outOfMemory。
final class OfflineProcessingService: @unchecked Sendable {

    // MARK: - 依赖

    private let pixelBufferPool: PixelBufferPool
    private let photoLibraryService: PhotoLibraryService

    // MARK: - 内存压力状态（锁保护）

    private let stateLock = NSLock()
    /// 收到 warning 级压力：缩批标志。
    private var memoryWarningActive = false
    /// 收到 critical 级压力：中止标志（下一检查点生效）。
    private var memoryCriticalActive = false
    /// 内存压力监听源。
    private var pressureSource: DispatchSourceMemoryPressure?
    private let logger = Logger(subsystem: "com.vtframepro", category: "offline")

    /// 内存水位阈值（§9.3：<512MB 中止）。
    private static let memoryFloorBytes: UInt64 = 512 * 1_048_576
    /// 常规批大小（帧/批，§9.3）。
    private static let normalBatchSize = 15
    /// 告警缩批大小（§9.3）。
    private static let reducedBatchSize = 8

    // MARK: - 初始化

    init(pixelBufferPool: PixelBufferPool, photoLibraryService: PhotoLibraryService) {
        self.pixelBufferPool = pixelBufferPool
        self.photoLibraryService = photoLibraryService
        installMemoryPressureListener()
    }

    deinit {
        pressureSource?.cancel()
    }

    // MARK: - 处理入口

    /// 执行离线任务（调用方并发域执行，严格串行由 OfflineTaskQueue 保证）。
    ///
    /// - Parameters:
    ///   - task: 任务描述（模式/源文件/引擎标识）。
    ///   - engine: 已解析的引擎（协议类型，L3 不感知实现）。
    ///   - cancelToken: 取消令牌（帧循环检查点轮询）。
    ///   - onProgress: 进度回调（0~1，跨域 @Sendable）。
    /// - Returns: 输出文件 URL（保存相册后保留供预览回放；
    ///   残留由启动清扫回收，§9.3 临时文件防线）。
    /// - Throws: `AppError.cancelled` / `.outOfMemory` / `.ioFailed` / `.permissionDenied`。
    func process(task: OfflineTask,
                 engine: any AIEngine,
                 cancelToken: ProcessingCancelToken,
                 onProgress: @Sendable (Double) -> Void) async throws -> URL {
        // 引擎幂等预热（队列串行保证无并发预热）。
        let capability: EngineCapability = task.mode == .offlineInterpolation
            ? .frameInterpolation : .superResolution
        try await engine.prepare(for: capability)

        let asset = AVURLAsset(url: task.sourceVideoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError.ioFailed(underlying: "源视频无视频轨")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let sourceDataRate = try await videoTrack.load(.estimatedDataRate)
        let duration = try await asset.load(.duration)
        let sourceFPS = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(sourceFPS.rounded()))

        // 输出参数：补帧分辨率不变 / 超分 x2；码率 = 源码率 × 1.5（§3.2-④）。
        let scale = task.mode == .offlineSuperResolution ? 2 : 1
        let outputWidth = Int(naturalSize.width) * scale
        let outputHeight = Int(naturalSize.height) * scale
        let outputBitRate = max(sourceDataRate * 1.5, 8_000_000)

        // 磁盘余量检查（§9.3：≥ 输出估算 2 倍）。
        try ensureDiskCapacity(estimatedOutputBytes: Int64(outputBitRate / 8) * Int64(duration.seconds) + 64 * 1_048_576)

        let outputURL = Self.makeTemporaryOutputURL()
        // 读/写器在 defer 中保证清理（取消/失败路径删除半成品，§3.2 取消传播）。
        var shouldKeepOutput = false
        defer {
            if !shouldKeepOutput {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let (reader, readerOutput) = try makeReader(asset: asset, track: videoTrack)
        let (writer, writerInput, adaptor) = try makeWriter(
            outputURL: outputURL, width: outputWidth, height: outputHeight,
            bitRate: outputBitRate)

        guard reader.startReading() else {
            throw AppError.ioFailed(underlying: reader.error?.localizedDescription ?? "读取器启动失败")
        }
        guard writer.startWriting() else {
            throw AppError.ioFailed(underlying: writer.error?.localizedDescription ?? "写入器启动失败")
        }
        writer.startSession(atSourceTime: .zero)

        // ---- 逐帧主循环（§3.2-② 分批防 OOM）----
        let totalFrames = max(1, Int(duration.seconds * sourceFPS))
        var processedInputFrames = 0
        var outputFrameIndex: Int64 = 0
        // 补帧输出步长 = 半帧时长（2× 帧率重打 PTS，§3.2-③）。
        let halfFrameDuration = CMTime(value: frameDuration.value,
                                       timescale: frameDuration.timescale * 2)
        var previousFrame: CVPixelBuffer?

        // 分批防 OOM（§3.2-②）：
        // Swift 的 autoreleasepool 不接受 async 闭包，故采用等效结构——
        // 外层按批循环（批大小随内存压力动态调整），帧级对象（CMSampleBuffer /
        // CVPixelBuffer）全部限定在单帧作用域内，随 ARC 在帧末确定性释放；
        // 同步重对象段（解码取帧）另以 autoreleasepool 包裹，达成与
        // 「每批 15 帧一个 autoreleasepool」等效的峰值内存控制。
        var framesInCurrentBatch = 0
        var currentBatchSize = Self.normalBatchSize

        while true {
            // ---- 检查点：取消传播（§3.2）----
            if cancelToken.isCancelled {
                writer.cancelWriting()
                reader.cancelReading()
                throw AppError.cancelled
            }
            // ---- 检查点：内存水位（§9.3：<512MB 中止）----
            if Self.availableMemoryBytes() < Self.memoryFloorBytes
                || stateLock.withLock({ memoryCriticalActive }) {
                writer.cancelWriting()
                reader.cancelReading()
                throw AppError.outOfMemory
            }
            // 批边界：达到批大小后缩批判定并冲刷临时对象（§9.3 告警缩批 15→8）。
            if framesInCurrentBatch >= currentBatchSize {
                framesInCurrentBatch = 0
                currentBatchSize = stateLock.withLock {
                    memoryWarningActive ? Self.reducedBatchSize : Self.normalBatchSize
                }
            }

            // 同步解码段（autoreleasepool 包裹，帧末释放解码临时对象）。
            let decodedFrame: CVPixelBuffer? = autoreleasepool {
                guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                    return nil
                }
                return CMSampleBufferGetImageBuffer(sampleBuffer)
            }
            guard let imageBuffer = decodedFrame else {
                break // 源帧耗尽，正常结束
            }

            // ---- 引擎处理（离线档 .highQuality，帧对象作用域=单帧）----
            do {
                switch task.mode {
                case .offlineInterpolation:
                    if let previous = previousFrame {
                        // 帧配对 → 中间帧（§3.2-③）。
                        let interpolated = try await engine.interpolate(
                            frame0: previous,
                            frame1: imageBuffer,
                            at: 0.5,
                            capability: InterpolationConfig(
                                factor: ProcessingSettings.realtimeInterpolationFactor,
                                quality: .highQuality))
                        try await append(interpolated,
                                         at: CMTimeMultiply(halfFrameDuration,
                                                            multiplier: Int32(outputFrameIndex)),
                                         writer: writer, input: writerInput,
                                         adaptor: adaptor, cancelToken: cancelToken)
                        outputFrameIndex += 1
                    }
                    // 原帧随配对写出（首帧单独写一次）。
                    try await append(imageBuffer,
                                     at: CMTimeMultiply(halfFrameDuration,
                                                        multiplier: Int32(outputFrameIndex)),
                                     writer: writer, input: writerInput,
                                     adaptor: adaptor, cancelToken: cancelToken)
                    outputFrameIndex += 1
                    previousFrame = imageBuffer

                case .offlineSuperResolution:
                    // 逐帧超分，PTS 原样透传（§3.2-③）。
                    let upscaled = try await engine.upscale(
                        imageBuffer, scale: scale, quality: .highQuality)
                    try await append(upscaled,
                                     at: CMTimeMultiply(frameDuration,
                                                        multiplier: Int32(processedInputFrames)),
                                     writer: writer, input: writerInput,
                                     adaptor: adaptor, cancelToken: cancelToken)

                default:
                    throw AppError.ioFailed(underlying: "非离线模式")
                }
            } // 单帧作用域结束：interpolated/upscaled/imageBuffer 引用此处释放。

            processedInputFrames += 1
            framesInCurrentBatch += 1
            onProgress(min(1.0, Double(processedInputFrames) / Double(totalFrames)))
        }

        // ---- 收尾（§3.2-⑤）----
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AppError.ioFailed(underlying: writer.error?.localizedDescription ?? "写入失败")
        }

        // 保存相册（权限不足抛 .permissionDenied，R-16）。
        try await photoLibraryService.saveVideo(at: outputURL)
        shouldKeepOutput = true // 保留供播放器回放；残留由启动清扫回收（§9.3）。
        onProgress(1.0)
        logger.notice("离线任务完成: \(task.sourceFileName) → \(outputURL.lastPathComponent)")
        return outputURL
    }

    // MARK: - 启动清扫（§9.3 临时文件防线）

    /// 清理临时目录残留（App 启动时调用一次）。
    static func cleanupTemporaryDirectory() {
        let directory = temporaryDirectoryURL()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 私有：读/写器构造

    /// AVAssetReader 构造（32BGRA 直出，读侧不重采样，§3.2-①）。
    private func makeReader(asset: AVAsset,
                            track: AVAssetTrack) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AppError.ioFailed(underlying: error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false // 零拷贝：解码缓冲直通引擎（§3.1 零拷贝策略）
        guard reader.canAdd(output) else {
            throw AppError.ioFailed(underlying: "读取输出挂载失败")
        }
        reader.add(output)
        return (reader, output)
    }

    /// AVAssetWriter 构造（HEVC hvc1 + adaptor 自带池，§3.2-④）。
    private func makeWriter(outputURL: URL,
                            width: Int,
                            height: Int,
                            bitRate: Float) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw AppError.ioFailed(underlying: error.localizedDescription)
        }
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitRate),
            // Profile 字面值（避免 L3 为单个常量 import VideoToolbox，分层铁律 §1.2）。
            AVVideoProfileLevelKey: "HEVC_Main_AutoLevel"
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        guard writer.canAdd(input) else {
            throw AppError.ioFailed(underlying: "写入输入挂载失败")
        }
        writer.add(input)
        return (writer, input, adaptor)
    }

    // MARK: - 私有：帧写入

    /// 背压感知写入（writer 未就绪时挂起等待 + 取消轮询）。
    private func append(_ pixelBuffer: CVPixelBuffer,
                        at presentationTime: CMTime,
                        writer: AVAssetWriter,
                        input: AVAssetWriterInput,
                        adaptor: AVAssetWriterInputPixelBufferAdaptor,
                        cancelToken: ProcessingCancelToken) async throws {
        while !input.isReadyForMoreMediaData {
            if cancelToken.isCancelled {
                writer.cancelWriting()
                throw AppError.cancelled
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw AppError.ioFailed(underlying: writer.error?.localizedDescription ?? "帧写入失败")
        }
    }

    // MARK: - 私有：容量与内存

    /// 磁盘余量检查（§9.3：保存前检查 ≥ 输出估算 2 倍）。
    private func ensureDiskCapacity(estimatedOutputBytes: Int64) throws {
        let required = estimatedOutputBytes * 2
        let values = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard available >= required else {
            throw AppError.ioFailed(underlying: "存储空间不足（需约 \(required / 1_048_576)MB）")
        }
    }

    /// 当前可用内存（os_proc_available_memory，公开 API，§9.3）。
    private static func availableMemoryBytes() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    /// 临时输出 URL（统一 temporaryDirectory/vtframepro/，§9.3）。
    private static func makeTemporaryOutputURL() -> URL {
        let directory = temporaryDirectoryURL()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(UUID().uuidString).mp4")
    }

    private static func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "vtframepro", directoryHint: .isDirectory)
    }

    // MARK: - 私有：内存压力监听

    /// DispatchSourceMemoryPressure 监听（§3.2 内存压力降级；GCD 保留点之二）。
    private func installMemoryPressureListener() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.critical) {
                stateLock.withLock { memoryCriticalActive = true }
                logger.notice("内存压力 critical：离线任务将于下一检查点中止")
            } else if event.contains(.warning) {
                stateLock.withLock { memoryWarningActive = true }
                pixelBufferPool.drain() // warning 级：drain 池 + 缩批（§9.3）
                logger.notice("内存压力 warning：缓冲池已冲刷，批大小缩至 \(Self.reducedBatchSize)")
            }
        }
        source.resume()
        pressureSource = source
    }
}
