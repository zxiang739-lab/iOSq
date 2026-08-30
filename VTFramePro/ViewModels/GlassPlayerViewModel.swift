//
//  GlassPlayerViewModel.swift
//  VTFramePro
//
//  自定义播放器 ViewModel：播放状态机 / 拖拽 seek 预览 / 长按加速 / 四档倍速（L2）。
//  对应 PRD R-06/07/08/09。
//

import Foundation
import AVFoundation
import Observation
import OSLog

/// 液态玻璃播放器 ViewModel。
///
/// 交互语义（PRD §3.2 播放器页）：
/// - R-06 进度条拖拽：拖动中实时 seek 预览目标时间点（isScrubbing 期不进自动隐藏）；
/// - R-07 点击画面：切换控制面板显隐（播放中 3s 无操作自动隐藏）；
/// - R-08 长按加速：按住临时 2.0x，松开恢复原速率；
/// - R-09 四档倍速：0.5x / 1.0x / 1.5x / 2.0x（AVPlayer 原生 rate）。
///
/// 线程：@MainActor（AVPlayer 全部操作在主线程，符合 AVFoundation 线程约定）。
@Observable
@MainActor
final class GlassPlayerViewModel {

    // MARK: - 播放器（View 渲染层直接持有）

    /// 播放核心（AVPlayerLayer 绑定）。
    let player: AVPlayer

    // MARK: - 可观察状态

    /// 播放中标志。
    private(set) var isPlaying = false
    /// 当前播放时间（秒，时间观察者驱动；拖拽期暂停驱动）。
    private(set) var currentTime: Double = 0
    /// 总时长（秒）。
    private(set) var duration: Double = 0
    /// 控制面板可见（R-07）。
    private(set) var isControlsVisible = true
    /// 拖拽中（R-06：拖拽期时间观察者不覆盖 scrub 值）。
    private(set) var isScrubbing = false
    /// 当前倍速（R-09；长按加速为临时态，不改此值）。
    private(set) var rate: Float = 1.0
    /// 长按加速中（R-08）。
    private(set) var isBoosting = false
    /// 播放就绪（item status → readyToPlay）。
    private(set) var isReady = false

    /// 四档倍速选项（R-09）。
    static let rateOptions: [Float] = [0.5, 1.0, 1.5, 2.0]
    /// 长按加速倍速（R-08）。
    static let boostRate: Float = 2.0

    // MARK: - 私有

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var autoHideTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.vtframepro", category: "ui")

    // MARK: - 初始化

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: item)

        // item 状态观察（就绪后可播）。
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.status == .readyToPlay {
                    isReady = true
                    duration = max(0, CMTimeGetSeconds(item.duration))
                }
            }
        }

        // 周期时间观察者（0.25s 粒度；拖拽期跳过，R-06）。
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !isScrubbing else { return }
                currentTime = max(0, CMTimeGetSeconds(time))
            }
        }

        // 播完：回到起点停住（可重播）。
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isPlaying = false
                player.pause()
                await player.seek(to: .zero)
                currentTime = 0
                showControls()
            }
        }
    }

    // Swift 6 隔离析构（SE-0371）：安全访问 @MainActor 隔离的播放器状态。
    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        statusObservation?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        autoHideTask?.cancel()
    }

    // MARK: - 播放 / 暂停

    /// 播放/暂停切换（控制面板主按钮）。
    func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.rate = isBoosting ? Self.boostRate : rate
            isPlaying = true
            scheduleAutoHide()
        }
    }

    // MARK: - 拖拽 seek（R-06）

    /// 拖拽开始：暂停时间驱动，进入 scrub 预览态。
    func beginScrubbing() {
        isScrubbing = true
        autoHideTask?.cancel()
    }

    /// 拖拽中：实时 seek 预览目标时间点（精确容差 .zero，R-06 预览语义）。
    func scrub(to fraction: Double) {
        guard duration > 0 else { return }
        let target = min(max(fraction, 0), 1) * duration
        currentTime = target
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 拖拽结束：退出 scrub 态，恢复时间驱动与自动隐藏。
    func endScrubbing() {
        isScrubbing = false
        if isPlaying {
            scheduleAutoHide()
        }
    }

    // MARK: - 面板显隐（R-07）

    /// 点击画面：切换控制面板显隐。
    func toggleControls() {
        if isControlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    /// 展示面板（并重置自动隐藏计时）。
    func showControls() {
        isControlsVisible = true
        if isPlaying {
            scheduleAutoHide()
        }
    }

    /// 隐藏面板。
    func hideControls() {
        autoHideTask?.cancel()
        isControlsVisible = false
    }

    // MARK: - 倍速（R-09）

    /// 设置档位倍速（播放中立即生效）。
    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying, !isBoosting {
            player.rate = newRate
        }
    }

    // MARK: - 长按加速（R-08）

    /// 长按开始：临时提速（原 rate 记忆，松开恢复）。
    func boostBegan() {
        guard isPlaying, !isBoosting else { return }
        isBoosting = true
        player.rate = Self.boostRate
    }

    /// 长按结束：恢复原档位速率。
    func boostEnded() {
        guard isBoosting else { return }
        isBoosting = false
        if isPlaying {
            player.rate = rate
        }
    }

    // MARK: - 收尾

    /// 页面退出：停播并释放观察者。
    func teardown() {
        player.pause()
        isPlaying = false
        autoHideTask?.cancel()
    }

    // MARK: - 私有：自动隐藏

    /// 播放中 3s 无操作自动隐藏面板。
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, isPlaying, !isScrubbing else { return }
            isControlsVisible = false
        }
    }
}
