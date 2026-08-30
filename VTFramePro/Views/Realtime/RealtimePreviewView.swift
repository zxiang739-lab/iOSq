//
//  RealtimePreviewView.swift
//  VTFramePro
//
//  实时预览页：摄像头预览 + 状态面板 + 控制条 + 下载三态 UI（L1 视图层）。
//  对应 PRD §3.2 实时预览页（R-10 面板、R-30 三态、R-11 权限引导）。
//

import SwiftUI
import CoreVideo
import MetalKit

/// 实时预览视图。
///
/// 组成：
/// - 预览层：`PixelBufferPreviewView`（CVPixelBuffer → Metal 纹理直渲，零拷贝，§3.1）；
/// - 顶部：GlassStatusPanel（FPS/延迟/占用）+ 估算图例；
/// - 中部：VT 下载三态横幅（下载中/失败重试/就绪）；
/// - 底部：启动/停止 + EnginePicker + 画质档位；
/// - 权限未授权：PermissionGuideView 引导。
struct RealtimePreviewView: View {

    /// 实时 ViewModel（按模式构造注入）。
    @State var viewModel: RealtimeViewModel

    /// DI 容器（EnginePicker 读取注册表）。
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 预览层。
            if let frame = viewModel.previewFrame {
                PixelBufferPreviewView(pixelBuffer: frame)
                    .ignoresSafeArea()
            } else {
                placeholderView
            }

            // 权限引导（已拒绝/受限时覆盖）。
            if viewModel.cameraPermission == .denied
                || viewModel.cameraPermission == .restricted {
                PermissionGuideView(
                    kind: .camera,
                    status: viewModel.cameraPermission,
                    onRequest: {
                        Task { await viewModel.startTapped() }
                    }
                )
            }

            // 顶部指标 + 底部控制。
            VStack(spacing: 10) {
                GlassStatusPanel(metrics: viewModel.metrics)
                MetricsEstimationFootnote()
                Spacer()
                engineStateBanner
                controlBar
            }
            .padding(16)
        }
        .navigationTitle(viewModel.mode.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // 离开页面即停链路（释放采集/引擎资源，§5.2 停止时序）。
            viewModel.stopTapped()
        }
        .alert("提示",
               isPresented: Binding(
                get: { viewModel.activeError != nil },
                set: { if !$0 { viewModel.activeError = nil } }
               ),
               presenting: viewModel.activeError) { _ in
            Button("知道了", role: .cancel) {}
        } message: { error in
            VStack {
                Text(error.errorDescription ?? "未知错误")
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                }
            }
        }
    }

    // MARK: - 占位视图（未启动）

    private var placeholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.mode.systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(viewModel.isStarting ? "正在启动…" : "点击下方「启动」开始预览")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 引擎状态三态横幅（R-30）

    @ViewBuilder
    private var engineStateBanner: some View {
        switch viewModel.engineState {
        case .modelDownloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress > 0 ? progress : nil)
                Text("系统模型下载中…")
                    .font(.caption)
            }
            .padding(10)
            .glassPanel(cornerRadius: 14)

        case .downloadFailed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                // R-30：失败可重试。
                Button("重试") {
                    Task { await viewModel.retryDownloadTapped() }
                }
                .font(.caption.weight(.semibold))
            }
            .padding(10)
            .glassPanel(cornerRadius: 14)

        case .unsupported(let reason):
            Label(reason, systemImage: "slash.circle")
                .font(.caption)
                .padding(10)
                .glassPanel(cornerRadius: 14)

        default:
            EmptyView()
        }
    }

    // MARK: - 底部控制条

    private var controlBar: some View {
        VStack(spacing: 12) {
            // 引擎选择（R-20；串联模式仅展示双能力引擎）。
            EnginePicker(
                requiredCapabilities: viewModel.mode.requiredCapabilities,
                selectedEngineID: viewModel.activeEngineID,
                onSelect: { engineID in
                    Task { await viewModel.selectEngine(id: engineID) }
                }
            )

            HStack(spacing: 12) {
                // 启动/停止主按钮。
                Button {
                    if viewModel.isRunning {
                        viewModel.stopTapped()
                    } else {
                        Task { await viewModel.startTapped() }
                    }
                } label: {
                    Label(viewModel.isRunning ? "停止" : "启动",
                          systemImage: viewModel.isRunning ? "stop.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .glassPanel(cornerRadius: 18, highlighted: viewModel.isRunning)
                }
                .disabled(viewModel.isStarting)

                // 画质档位（R-21/R-29）。
                Menu {
                    ForEach(RealtimeQualityTier.allCases, id: \.self) { tier in
                        Button {
                            viewModel.selectQualityTier(tier)
                        } label: {
                            if tier == viewModel.qualityTier {
                                Label(tier.displayName, systemImage: "checkmark")
                            } else {
                                Text(tier.displayName)
                            }
                        }
                    }
                } label: {
                    Label(viewModel.qualityTier.displayName, systemImage: "slider.horizontal.3")
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .glassPanel(cornerRadius: 18)
                }
            }
        }
    }
}

// MARK: - Metal 预览渲染

/// CVPixelBuffer → Metal 纹理直渲（零拷贝上屏，§3.1）。
///
/// 实现：MTKView + CIContext(MTLDevice)——CIImage 直接引用 CVPixelBuffer
/// （CVMetalTextureCache 由 CoreImage 内部维护），渲染到 drawable 纹理，
/// 全程无 CPU 像素拷贝。
private struct PixelBufferPreviewView: UIViewRepresentable {

    let pixelBuffer: CVPixelBuffer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        // framebufferOnly=false：允许 CIContext 直接渲染进 drawable 纹理。
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.contentMode = .scaleAspectFill
        if let device = view.device {
            context.coordinator.ciContext = CIContext(mtlDevice: device)
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        guard let ciContext = context.coordinator.ciContext,
              let drawable = uiView.currentDrawable,
              uiView.drawableSize.width > 0, uiView.drawableSize.height > 0 else { return }

        // aspectFill 等比放大 + 居中裁剪。
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = max(uiView.drawableSize.width / image.extent.width,
                        uiView.drawableSize.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translation = CGAffineTransform(
            translationX: (uiView.drawableSize.width - scaled.extent.width) / 2 - scaled.extent.origin.x,
            y: (uiView.drawableSize.height - scaled.extent.height) / 2 - scaled.extent.origin.y
        )
        let fitted = scaled.transformed(by: translation)

        ciContext.render(
            fitted,
            to: drawable.texture,
            commandBuffer: nil,
            bounds: CGRect(origin: .zero, size: uiView.drawableSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        drawable.present()
    }

    final class Coordinator {
        var ciContext: CIContext?
    }
}
