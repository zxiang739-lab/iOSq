# VTFramePro

双 AI 引擎视频增强 iOS App：实时/离线 **补帧** 与 **超分**，系统 `VTFrameProcessor` 与用户导入 CoreML 模型经统一协议抽象自由切换，全程 Liquid Glass 原生 UI。

- 平台：**纯 iOS**（仅 iPhone），部署目标 **iOS 26.0**，兼容 iOS 27
- 技术栈：Swift 6（严格并发 complete）/ SwiftUI（iOS 26 Liquid Glass）/ AVFoundation / VideoToolbox / CoreML / MetalPerformanceShaders / Photos
- 依赖：**零第三方**（无 FFmpeg/SPM/CocoaPods/私有 API），**不内置任何模型**

---

## 1. 五种业务模式

| 模式 | 链路 | 说明 |
|---|---|---|
| 实时补帧 | AVCaptureSession 720p30 → 帧插值 → 60fps 预览 | 端到端延迟目标 <150ms |
| 实时超分 | 摄像头 → x2 超分 → 预览 | 低延迟档 |
| 实时补帧+超分 | 插值 → 序列展开 → 超分（串联） | 「性能」档自动关超分级 |
| 离线补帧 | AVAssetReader → 帧配对插值 → 2× 帧率 HEVC | 分辨率不变，保存相册 |
| 离线超分 | AVAssetReader → x2 超分 → HEVC（hvc1） | 高质量档，码率 = 源 ×1.5 |

离线任务**严格串行**排队、可取消、分批防 OOM（每帧检查取消点与内存水位 <512MB 中止）。

## 2. 双引擎与切换

| 引擎 | 来源 | 能力 | 说明 |
|---|---|---|---|
| 系统 VT 引擎 | iOS 26 `VTFrameProcessor` | 补帧 + 超分 | 启动/回前台做 `isSupported` 运行时检测；系统模型下载三态（下载中/失败可重试/完成） |
| 导入模型引擎 | 用户导入 `.mlpackage` | 导入时声明（补帧 或 超分） | CoreML + MPS，`computeUnits = .all`（ANE+GPU 自动调度） |

- **切换入口**：实时预览页与离线任务页的「引擎」选择器；模型库可「设为当前」。
- **降级策略**：当前引擎不可用 → 自动回落第一个就绪引擎（横幅告知）；全部不可用 → 入口置灰 + 原因。
- **热切换**：运行中切换引擎时旧引擎 `reset()`、新引擎 `prepare()`，预热完成前原始帧直通，不黑屏。

## 3. 硬件要求

- **iPhone 15 Pro（A17 Pro）及以上**，iOS 26.0+（以运行时 `isSupported` 检测为准；不支持的设备 VT 入口置灰，可改用导入模型）。
- 仅真机（Apple Silicon）；`VTFrameProcessor` 在模拟器不可用（SDK 头文件即禁用），本工程不含任何模拟器专用代码。
- 自定义模型引擎对硬件无额外要求（CoreML 自动调度 ANE/GPU/CPU）。

## 4. mlpackage 张量规格约定（导入校验规则）

导入时校验，**任一不满足即拒绝入库并逐条提示原因**：

1. **输入/输出张量数与声明用途匹配**：补帧 = 2 帧输入 → 1 帧输出；超分 = 1 帧输入 → 1 帧输出（补帧模型允许额外 1 个标量输入承载插值相位 timestep）。
2. **像素格式/通道**：RGB interleaved（3 通道）或 `kCVPixelFormatType_32BGRA`（4 通道）。
3. **超分输出尺寸**：输出 H/W 必须为输入的整数倍（首版约定 x2 或 x4）。
4. **批次 = 1**。
5. **形状静态**：不接受动态 shape。

帧张量接受 `image` 类型或 ≥3 维 `multiArray`（NCHW/NHWC/CHW/HWC 均可识别）。模型文件存入 App 沙盒 `Documents/ImportedModels/`，可经「文件」App 管理；App 不内置、不上传任何模型。

## 5. 编译与运行

### 环境
- **Xcode 26 或更高**（工程采用 Xcode 16+ file-system-synchronized groups，磁盘目录即工程结构，新增文件无需登记 pbxproj）。
- Apple ID 签名（免费证书即可真机调试）。

### 步骤
1. `git clone` 后用 Xcode 26 打开 `VTFramePro.xcodeproj`。
2. 选择 target `VTFramePro` → Signing & Capabilities 设置你的 Development Team（`project.pbxproj` 中 `DEVELOPMENT_TEAM` 为占位空值）。
3. 连接 iPhone（iOS 26+），选择真机运行（⌘R）。
4. 首次进入「模型库」可查看系统 VT 引擎能力检测结果；使用系统引擎时首次 `prepare` 可能触发系统模型下载（界面有三态提示与重试）。

### 打包 Unsigned IPA（无需签名配置）

仓库提供一键脚本 `scripts/package-ipa.sh`：**无签名构建** → 导出 `VTFramePro-unsigned-<配置>.ipa`。只需 Mac + Xcode 26，**无需任何证书 / Team ID / Secrets**。

```bash
# Release（默认）
bash scripts/package-ipa.sh

# Debug
bash scripts/package-ipa.sh --configuration Debug
```

产物：`build/ipa/VTFramePro-unsigned-Release.ipa`（或 Debug 同名后缀）

> 该 IPA 未签名：可自行用 Apple 证书（开发 / Ad Hoc / App Store）签名后安装，或用 sideloadly 等工具侧载到已登记设备；App Store 上架请在 `Xcode → Archive` 中以正式签名重新导出。

GitHub Actions 一键打包：**Actions → Build Unsigned IPA → Run workflow**，无需配置任何 Secrets。

### 权限（Info.plist 已含全部键）
- `NSCameraUsageDescription`（实时预览）
- `NSPhotoLibraryUsageDescription`（读取素材）
- `NSPhotoLibraryAddUsageDescription`（保存结果）

## 6. 架构速览

```
L1 Views（SwiftUI，禁 import CoreML/VideoToolbox）
L2 ViewModels（@MainActor @Observable，唯一编排层）
L3 Services（采集/实时流水线/离线处理/模型库，只面向 AIEngine 协议）
L4 AIEngines（AIEngine 协议 / EngineRegistry / VT 引擎 / CoreML 引擎 / 张量校验）
L5 Models（纯值类型与统一错误域 AppError）
```

详见 `docs/ARCHITECTURE.md`（含类图/时序图 mermaid 源）。

## 7. 已知性能限制

- **实时串联模式**在 720p 下插值 + 双路超分对 ANE/GPU 压力大，「性能」档或热降档时自动关闭超分级保底；详见 `docs/PERFORMANCE.md`。
- **补帧倍率锁 x2**（实时/离线均如此）：x4 推理开销 ×3，必然击穿 150ms 延迟预算；`InterpolationConfig.factor` 已预留，后续经性能验证再开放。
- **GPU/ANE 占用为估算值**：iOS 无公开精确计数 API（IOReport 属私有），以推理耗时占帧预算比估算并在 UI 标注。
- **离线任务退后台暂停**（首版未开 Background Modes），回前台续跑；输出临时文件保留至下次启动清扫（用于完成回放）。
- **VTFrameProcessor 符号**：以 Xcode 26 SDK 实际头文件为准（代码内 `※SDK` 标注点：`VTFrameRateConversionConfiguration` 的 `qualityPrioritization/revision` 枚举名、`VTSuperResolutionScalerConfiguration/Parameters` 初始化签名、`supportedScaleFactors` 方法名）。
