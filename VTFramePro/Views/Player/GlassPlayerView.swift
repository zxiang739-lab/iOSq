//
//  GlassPlayerView.swift
//  VTFramePro
//
//  自定义 SwiftUI AVPlayer + 液态玻璃控制面板（L1 视图层）。
//  对应 PRD R-06/07/08/09 全部播放器交互。
//

import SwiftUI
import AVFoundation

/// 液态玻璃播放器页面。
///
/// 交互映射（全部经 ViewModel 编排，View 不触推理）：
/// - 点击画面 → 控制面板显隐（R-07）；
/// - 进度条拖拽 → 拖动中实时预览（R-06）；
/// - 长按画面 → 临时 2.0x 加速，松开恢复（R-08）；
/// - 倍速按钮 → 0.5x/1.0x/1.5x/2.0x（R-09）。
struct GlassPlayerView: View {

    /// 播放 ViewModel（按 URL 构造，页面级持有）。
    @State private var viewModel: GlassPlayerViewModel

    /// 关闭动作（导航栈出栈）。
    @Environment(\.dismiss) private var dismiss

    init(url: URL) {
        _viewModel = State(initialValue: GlassPlayerViewModel(url: url))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 视频渲染层（AVPlayerLayer 包装，零拷贝上屏）。
            PlayerLayerView(player: viewModel.player)
                .ignoresSafeArea()
                // R-07：点击显隐面板。
                .onTapGesture {
                    viewModel.toggleControls()
                }
                // R-08：长按加速 / 松开恢复。
                .onLongPressGesture(
                    minimumDuration: 0.35,
                    maximumDistance: 50,
                    pressing: { pressing in
                        if pressing {
                            viewModel.boostBegan()
                        } else {
                            viewModel.boostEnded()
                        }
                    },
                    perform: {}
                )

            // 控制面板（显隐动画）。
            if viewModel.isControlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }

            // 长按加速指示。
            if viewModel.isBoosting {
                VStack {
                    Text("2.0x 加速中")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassPanel(cornerRadius: 12)
                    Spacer()
                }
                .padding(.top, 60)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.isControlsVisible)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(!viewModel.isControlsVisible)
        .onDisappear {
            viewModel.teardown()
        }
    }

    // MARK: - 控制面板

    /// 顶部关闭条 + 底部控制条（液态玻璃材质）。
    private var controlsOverlay: some View {
        VStack {
            // 顶部：关闭按钮。
            HStack {
                Button {
                    viewModel.teardown()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .glassPanel(cornerRadius: 18)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            // 底部：进度 + 播放控制 + 倍速。
            VStack(spacing: 12) {
                // 进度条（R-06 拖拽预览）。
                HStack(spacing: 8) {
                    Text(Self.timeText(viewModel.currentTime))
                        .font(.caption.monospacedDigit())
                    Slider(
                        value: Binding(
                            get: {
                                viewModel.duration > 0
                                    ? viewModel.currentTime / viewModel.duration : 0
                            },
                            set: { viewModel.scrub(to: $0) }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if editing {
                                viewModel.beginScrubbing()
                            } else {
                                viewModel.endScrubbing()
                            }
                        }
                    )
                    Text(Self.timeText(viewModel.duration))
                        .font(.caption.monospacedDigit())
                }

                HStack(spacing: 24) {
                    // 播放/暂停。
                    Button {
                        viewModel.togglePlayPause()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 52, height: 52)
                            .glassPanel(cornerRadius: 26)
                    }

                    // 四档倍速（R-09）。
                    HStack(spacing: 8) {
                        ForEach(GlassPlayerViewModel.rateOptions, id: \.self) { option in
                            Button {
                                viewModel.setRate(option)
                            } label: {
                                Text(Self.rateText(option))
                                    .font(.caption.weight(
                                        viewModel.rate == option ? .bold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .glassPanel(cornerRadius: 10,
                                                highlighted: viewModel.rate == option)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .glassPanel(cornerRadius: 24)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - 文案工具

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func rateText(_ rate: Float) -> String {
        rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fx", rate)
            : String(format: "%.1fx", rate)
    }
}

// MARK: - AVPlayerLayer 渲染包装

/// AVPlayerLayer 的 UIView 包装（自定义控制层因此可完全 SwiftUI 化）。
private struct PlayerLayerView: UIViewRepresentable {

    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerBackingView {
        let view = PlayerBackingView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerBackingView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    /// 以 layerClass 方式承载 AVPlayerLayer（布局随 SwiftUI 自动同步）。
    final class PlayerBackingView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
