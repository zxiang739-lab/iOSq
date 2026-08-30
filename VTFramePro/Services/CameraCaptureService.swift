//
//  CameraCaptureService.swift
//  VTFramePro
//
//  AVCaptureSession 720p30 采集，AsyncStream 输出（L3 媒体服务层）。
//  对应 ARCHITECTURE.md §3.1 实时链路采集段（R-01/02/03）。
//

import Foundation
import AVFoundation
import OSLog

/// 摄像头采集服务。
///
/// 配置（§3.1）：
/// - preset `.hd1280x720`（720p 上限）、锁 30fps；
/// - `AVCaptureVideoDataOutput` 挂 serial `captureQueue`（.userInteractive）；
/// - `alwaysDiscardsLateVideoFrames = true`（系统级丢帧兜底，三层背压之一）；
/// - 输出像素格式 32BGRA（与引擎/池约定一致）。
///
/// 桥接（§8.3）：Delegate 就地桥接为 `AsyncStream`（`.bufferingNewest(1)`，
/// 新帧覆盖旧帧，绝不排队积压）。
///
/// 线程：采集回调在 captureQueue；`start/stop` 内部切到 sessionQueue 串行配置，
/// 类本体 `@unchecked Sendable`（Delegate 由系统在非主线程回调）。
final class CameraCaptureService: NSObject,
                                  AVCaptureVideoDataOutputSampleBufferDelegate,
                                  @unchecked Sendable {

    // MARK: - 输出

    /// 帧流（`.bufferingNewest(1)`：latest-frame-wins，§3.1 背压第二层）。
    let sampleBuffers: AsyncStream<CMSampleBuffer>

    // MARK: - 依赖与私有

    private let permissionService: PermissionService
    private let continuation: AsyncStream<CMSampleBuffer>.Continuation
    /// 采集会话（仅 sessionQueue 访问）。
    private let session = AVCaptureSession()
    /// 会话配置串行队列（GCD 保留点之一，§8.3）。
    private let sessionQueue = DispatchQueue(label: "com.vtframepro.capture.session")
    /// 帧回调串行队列（系统要求 GCD，§8.3）。
    private let captureQueue = DispatchQueue(label: "com.vtframepro.capture.output",
                                             qos: .userInteractive)
    private let stateLock = NSLock()
    private var isRunning = false
    private let logger = Logger(subsystem: "com.vtframepro", category: "media")

    // MARK: - 初始化

    init(permissionService: PermissionService) {
        self.permissionService = permissionService
        var continuation: AsyncStream<CMSampleBuffer>.Continuation!
        self.sampleBuffers = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.continuation = continuation
        super.init()
    }

    deinit {
        continuation.finish()
    }

    // MARK: - 启动

    /// 检查权限并启动采集（幂等）。
    ///
    /// - Throws: `AppError.permissionDenied(.camera)` / `.ioFailed`（无可用摄像头）。
    func start() async throws {
        guard !stateLock.withLock({ isRunning }) else { return }

        // 权限检查（未决定则现场申请，R-11）。
        let status = await permissionService.request(.camera)
        guard status.isGranted else {
            throw AppError.permissionDenied(.camera)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configureSessionIfNeeded()
                    session.startRunning()
                    stateLock.withLock { isRunning = true }
                    logger.notice("摄像头采集已启动（720p30）")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 停止

    /// 停止采集（幂等；帧流保持存活供下次启动复用）。
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                stateLock.withLock { isRunning = false }
                logger.notice("摄像头采集已停止")
                continuation.resume()
            }
        }
    }

    // MARK: - 私有：会话配置

    /// 惰性配置会话（仅首次；sessionQueue 上调用）。
    private func configureSessionIfNeeded() throws {
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1280x720

        // 后置广角摄像头。
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            throw AppError.ioFailed(underlying: "无可用后置摄像头")
        }

        // 锁 30fps（min=max，§3.1）。
        do {
            try device.lockForConfiguration()
            let frameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            throw AppError.ioFailed(underlying: "摄像头参数锁定失败：\(error.localizedDescription)")
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AppError.ioFailed(underlying: "摄像头输入挂载失败")
        }
        session.addInput(input)

        // 视频数据输出：32BGRA + 系统级丢帧。
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw AppError.ioFailed(underlying: "摄像头输出挂载失败")
        }
        session.addOutput(output)

        // 竖屏取向（首版竖屏，§7.2）。
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate（captureQueue 回调）

    /// 帧回调：就地桥接进 AsyncStream（§8.3，禁止 Delegate 跨层传播）。
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        continuation.yield(sampleBuffer)
    }
}
