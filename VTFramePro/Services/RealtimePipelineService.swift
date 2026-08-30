//
//  RealtimePipelineService.swift
//  VTFramePro
//
//  实时帧流调度：配对 / 推理门闩 / 丢帧 / DisplayLink 输出（L3 媒体服务层）。
//  对应 ARCHITECTURE.md §3.1 实时链路（R-01/02/03，端到端 <150ms）。
//
//  背压三层（§3.1）：
//  ① 采集侧 AsyncStream(.bufferingNewest(1))（CameraCaptureService 内）；
//  ② 本服务推理门闩：同一时刻仅 1 次推理在飞，在飞期间新帧执行 latest-frame-wins 覆盖；
//  ③ 系统层 alwaysDiscardsLateVideoFrames（CameraCaptureService 内）。
//
//  引擎热切换（§2.3）：下一帧边界旧引擎 reset()、新引擎 prepare()，
//  预热完成前原始帧直通，避免黑屏/断帧。
//

import Foundation
import AVFoundation
import QuartzCore
import OSLog

/// 实时流水线服务。
///
/// 只面向 `AIEngine` 协议编程（§1.2 第 2 条），不感知具体引擎类型。
/// 线程：@unchecked Sendable——内部全部可变状态由 `stateLock` 保护；
/// 帧仅传引用（CVPixelBuffer 零拷贝，§8.4）。
final class RealtimePipelineService: @unchecked Sendable {

    // MARK: - 输出

    /// 预览帧流（`start` 后可用；DisplayLink 节拍驱动）。
    private(set) var previewFrames: AsyncStream<CVPixelBuffer>?

    // MARK: - 依赖

    private let pixelBufferPool: PixelBufferPool
    private let metricsCollector: MetricsCollector

    // MARK: - 运行态（stateLock 保护）

    private let stateLock = NSLock()
    /// 当前模式。
    private var mode: ProcessingMode = .realtimeInterpolation
    /// 画质档位（串联模式下「性能」档自动关超分级，§9.2-2/9.2-3）。
    private var qualityTier: RealtimeQualityTier = .balanced
    /// 当前生效引擎（协议类型，L3 不感知实现）。
    private var engine: (any AIEngine)?
    /// 补帧配对缓冲：上一帧（仅持引用）。
    private var previousFrame: CVPixelBuffer?
    private var previousPTS: CMTime = .invalid
    /// 待处理最新帧（latest-frame-wins：在飞期间被新帧覆盖）。
    private var pendingFrame: CVPixelBuffer?
    private var pendingPTS: CMTime = .invalid
    /// 推理门闩：同一时刻仅 1 次推理在飞。
    private var inferenceInFlight = false
    /// 输出槽位：最近原始帧 / 最近中间帧 / 最近处理帧（SR 结果）。
    private var latestOriginal: CVPixelBuffer?
    private var latestOriginalPTS: CMTime = .invalid
    private var latestInterpolated: CVPixelBuffer?
    private var latestProcessed: CVPixelBuffer?
    /// DisplayLink 节拍奇偶（补帧 2× 节拍：原帧/中间帧交替）。
    private var outputTickParity = false
    /// 引擎预热中（切换期原始帧直通，§2.3 热切换）。
    private var engineSwitching = false
    /// 运行标志。
    private var isRunning = false

    /// 输入消费任务。
    private var consumerTask: Task<Void, Never>?
    /// DisplayLink 驱动。
    private var displayDriver: DisplayLinkDriver?
    /// 预览流 continuation。
    private var previewContinuation: AsyncStream<CVPixelBuffer>.Continuation?
    private let logger = Logger(subsystem: "com.vtframepro", category: "media")

    // MARK: - 初始化

    init(pixelBufferPool: PixelBufferPool, metricsCollector: MetricsCollector) {
        self.pixelBufferPool = pixelBufferPool
        self.metricsCollector = metricsCollector
    }

    // MARK: - 启动

    /// 启动流水线。
    ///
    /// - Parameters:
    ///   - mode: 业务模式（实时三种之一）。
    ///   - engine: 已解析并 prepare 完成的引擎（由 ViewModel 经 EngineRegistry 注入）。
    ///   - input: 采集帧流（CameraCaptureService.sampleBuffers）。
    ///   - qualityTier: 画质档位（默认均衡；「性能」档串联模式自动关超分级）。
    /// - Throws: `AppError.noUsableEngine`（引擎未就绪）。
    func start(mode: ProcessingMode,
               engine: any AIEngine,
               input: AsyncStream<CMSampleBuffer>,
               qualityTier: RealtimeQualityTier = .balanced) async throws {
        guard mode.isRealtime else {
            throw AppError.ioFailed(underlying: "非实时模式不能启动实时流水线")
        }
        guard engine.state.isUsable else {
            throw AppError.noUsableEngine(capability: mode.requiredCapabilities.first ?? .frameInterpolation)
        }

        stateLock.withLock {
            self.mode = mode
            self.engine = engine
            self.qualityTier = qualityTier
            previousFrame = nil
            pendingFrame = nil
            latestOriginal = nil
            latestInterpolated = nil
            latestProcessed = nil
            inferenceInFlight = false
            engineSwitching = false
            isRunning = true
        }

        // 预览帧流：无缓冲（DisplayLink 节拍即生产节拍，消费者为 UI 渲染）。
        var continuation: AsyncStream<CVPixelBuffer>.Continuation!
        let stream = AsyncStream<CVPixelBuffer> { continuation = $0 }
        stateLock.withLock { previewContinuation = continuation }
        previewFrames = stream

        // 指标采集启动（帧预算：补帧 2× 节拍约 16.7ms，其余 33.3ms）。
        let budgetMs = mode.outputCadenceMultiplier == 2 ? 16.7 : 33.3
        metricsCollector.start(frameBudgetMs: budgetMs)

        // DisplayLink 输出驱动：补帧类模式 2× 节拍（60Hz），其余 1×（30Hz）。
        let driver = DisplayLinkDriver { [weak self] in
            self?.emitOutputFrame()
        }
        driver.start(preferredFramesPerSecond: mode.outputCadenceMultiplier == 2 ? 60 : 30)
        displayDriver = driver

        // 输入消费任务：采集帧 → 提交调度。
        consumerTask = Task { [weak self] in
            for await sampleBuffer in input {
                guard let self, self.stateLock.withLock({ self.isRunning }) else { return }
                self.submit(sampleBuffer: sampleBuffer)
            }
        }
        logger.notice("实时流水线已启动: \(mode.displayName)")
    }

    // MARK: - 引擎热切换

    /// 运行中切换引擎（§2.3）：下一帧边界旧引擎 reset、新引擎 prepare，
    /// 预热完成前原始帧直通。
    ///
    /// - Parameter engine: 新引擎（协议类型）。
    func switchEngine(to newEngine: any AIEngine) async {
        let (oldEngine, capability) = stateLock.withLock { () -> ((any AIEngine)?, EngineCapability) in
            engineSwitching = true
            return (engine, mode.requiredCapabilities.first ?? .frameInterpolation)
        }
        // 帧边界：推理门闩保证此处无在飞推理的写入冲突（新帧在 switching 期直通）。
        if let oldEngine {
            await oldEngine.reset()
        }
        do {
            try await newEngine.prepare(for: capability)
        } catch {
            logger.error("引擎切换预热失败: \(error.localizedDescription)")
        }
        stateLock.withLock {
            engine = newEngine
            engineSwitching = false
            // 清配对缓冲，避免跨引擎配对（旧引擎帧与新引擎帧混插）。
            previousFrame = nil
            pendingFrame = nil
            latestInterpolated = nil
            latestProcessed = nil
        }
        logger.notice("引擎已热切换: \(newEngine.displayName)")
    }

    // MARK: - 停止

    /// 停止流水线（清配对缓冲 / 丢帧门闩 / DisplayLink / 指标）。
    func stop() async {
        let task = stateLock.withLock { () -> Task<Void, Never>? in
            isRunning = false
            let consumer = consumerTask
            consumerTask = nil
            previousFrame = nil
            pendingFrame = nil
            latestOriginal = nil
            latestInterpolated = nil
            latestProcessed = nil
            inferenceInFlight = false
            return consumer
        }
        task?.cancel()
        displayDriver?.stop()
        displayDriver = nil
        metricsCollector.stop()
        stateLock.withLock {
            previewContinuation?.finish()
            previewContinuation = nil
        }
        previewFrames = nil
        logger.notice("实时流水线已停止")
    }

    // MARK: - 私有：帧提交与推理调度

    /// 采集帧提交（captureQueue → 消费任务上下文）。
    private func submit(sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // latest-frame-wins：覆盖待处理帧（§3.1 背压第二层）。
        let shouldLaunch = stateLock.withLock { () -> Bool in
            pendingFrame = imageBuffer
            pendingPTS = pts
            // 引擎切换期：直接直通上屏，不进入推理。
            if engineSwitching {
                latestOriginal = imageBuffer
                latestOriginalPTS = pts
            }
            return !inferenceInFlight && !engineSwitching
        }
        if shouldLaunch {
            launchInference()
        }
    }

    /// 启动一次推理（门闩内调用；完成后续接 pending 帧形成泵）。
    private func launchInference() {
        guard let work = stateLock.withLock({ () -> InferenceWork? in
            guard let engine,
                  let pending = pendingFrame,
                  pendingPTS.isValid else { return nil }
            inferenceInFlight = true
            pendingFrame = nil
            let work = InferenceWork(
                mode: mode,
                qualityTier: qualityTier,
                current: pending,
                currentPTS: pendingPTS,
                previous: previousFrame,
                engine: engine
            )
            // 补帧配对：当前帧成为下一次的上一帧（§3.1-① 帧配对）。
            previousFrame = pending
            previousPTS = pendingPTS
            return work
        }) else {
            stateLock.withLock { inferenceInFlight = false }
            return
        }

        // 原始帧无条件进入输出槽（上屏兜底：推理慢时仍按采集帧率出原帧）。
        stateLock.withLock {
            latestOriginal = work.current
            latestOriginalPTS = work.currentPTS
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performInference(work)
            } catch {
                // 推理失败不致命：丢此帧的增强结果，原帧已入槽保底。
                self.logger.error("推理失败（已丢帧保底）: \(error.localizedDescription)")
            }
            let durationMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            self.metricsCollector.recordInference(durationMs: durationMs)
            // 门闩释放 + 泵：在飞期间到达的新帧立即续接。
            let hasMore = self.stateLock.withLock { () -> Bool in
                inferenceInFlight = false
                return pendingFrame != nil && isRunning && !engineSwitching
            }
            if hasMore {
                self.launchInference()
            }
        }
    }

    /// 按模式执行推理并写入输出槽。
    private func performInference(_ work: InferenceWork) async throws {
        switch work.mode {
        case .realtimeInterpolation:
            // 补帧：需成对帧，首帧无配对则跳过（原帧已保底）。
            guard let previous = work.previous else { return }
            let interpolated = try await work.engine.interpolate(
                frame0: previous,
                frame1: work.current,
                at: 0.5,
                capability: InterpolationConfig(factor: ProcessingSettings.realtimeInterpolationFactor,
                                                quality: .lowLatency)
            )
            stateLock.withLock { latestInterpolated = interpolated }

        case .realtimeSuperResolution:
            // 超分：逐帧直送。
            let upscaled = try await work.engine.upscale(
                work.current,
                scale: 2,
                quality: .lowLatency
            )
            stateLock.withLock { latestProcessed = upscaled }

        case .realtimeCombined:
            // 串联：插值 → 序列展开 → 超分（§3.1-①）。
            // 「性能」档或热降档时自动关超分级（§9.2-2/9.2-3）。
            guard let previous = work.previous else { return }
            let interpolated = try await work.engine.interpolate(
                frame0: previous,
                frame1: work.current,
                at: 0.5,
                capability: InterpolationConfig(factor: ProcessingSettings.realtimeInterpolationFactor,
                                                quality: .lowLatency)
            )
            if work.qualityTier == .performance {
                // 关超分级：中间帧直出（降档保底）。
                stateLock.withLock { latestInterpolated = interpolated }
                return
            }
            // 超分级：原帧与中间帧各放大一次。
            let upscaledOriginal = try await work.engine.upscale(
                work.current, scale: 2, quality: .lowLatency)
            let upscaledInterpolated = try await work.engine.upscale(
                interpolated, scale: 2, quality: .lowLatency)
            stateLock.withLock {
                latestProcessed = upscaledOriginal
                latestInterpolated = upscaledInterpolated
            }

        default:
            // 离线模式不走实时流水线。
            break
        }
    }

    // MARK: - 私有：DisplayLink 输出

    /// DisplayLink 节拍：按模式输出槽位帧。
    ///
    /// 节拍策略（§3.1-③）：
    /// - 补帧类 2× 节拍：原帧 / 中间帧交替（无中间帧时重复原帧）；
    /// - 超分类 1× 节拍：有处理帧出处理帧，否则原帧直通。
    private func emitOutputFrame() {
        let (frame, pts) = stateLock.withLock { () -> (CVPixelBuffer?, CMTime) in
            guard isRunning else { return (nil, .invalid) }
            outputTickParity.toggle()
            switch mode {
            case .realtimeInterpolation:
                // 偶数拍原帧，奇数拍中间帧（无中间帧兜底原帧）。
                if outputTickParity, let interpolated = latestInterpolated {
                    return (interpolated, latestOriginalPTS)
                }
                return (latestOriginal, latestOriginalPTS)

            case .realtimeSuperResolution:
                return (latestProcessed ?? latestOriginal, latestOriginalPTS)

            case .realtimeCombined:
                if outputTickParity, let interpolated = latestInterpolated {
                    return (interpolated, latestOriginalPTS)
                }
                return (latestProcessed ?? latestOriginal, latestOriginalPTS)

            default:
                return (latestOriginal, latestOriginalPTS)
            }
        }
        guard let frame else { return }
        if pts.isValid {
            metricsCollector.recordDisplayedFrame(capturePTS: pts)
        }
        stateLock.withLock { previewContinuation?.yield(frame) }
    }
}

// MARK: - 推理工作单元

/// 一次推理所需的全部输入（值快照，跨任务传递）。
private struct InferenceWork: @unchecked Sendable {
    let mode: ProcessingMode
    let qualityTier: RealtimeQualityTier
    let current: CVPixelBuffer
    let currentPTS: CMTime
    let previous: CVPixelBuffer?
    let engine: any AIEngine
}

// MARK: - DisplayLink 驱动

/// CADisplayLink 包装（输出节拍驱动）。
///
/// CADisplayLink 需挂主 RunLoop；tick 回调经 @Sendable 闭包转发给流水线
/// （流水线内部状态锁保护，跨线程安全）。
private final class DisplayLinkDriver: NSObject, @unchecked Sendable {

    private let handler: @Sendable () -> Void
    private let lock = NSLock()
    private var displayLink: CADisplayLink?

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        super.init()
    }

    /// 启动节拍（主线程挂接）。
    func start(preferredFramesPerSecond: Int) {
        DispatchQueue.main.async { [self] in
            let link = CADisplayLink(target: self, selector: #selector(tick))
            let rate = Float(preferredFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: rate / 2, maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            lock.withLock { displayLink = link }
        }
    }

    /// 停止节拍。
    func stop() {
        let link = lock.withLock { () -> CADisplayLink? in
            let current = displayLink
            displayLink = nil
            return current
        }
        DispatchQueue.main.async {
            link?.invalidate()
        }
    }

    @objc private func tick() {
        handler()
    }
}
