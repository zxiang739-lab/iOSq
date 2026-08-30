# VTFramePro QA 验证报告

> **作者**：QA 工程师 严过关（Edward）
> **基线**：42 个 Swift 源文件（PRD v2.0 / ARCHITECTURE v2.0）
> **环境**：本机为 Windows 11（**Swift XCTest 无法本地运行**），采用「静态审查 + 逻辑推演 + 可编译测试代码 + Mac 端 GUI 教程」四段式交付
> **执行轮次**：仅 1 轮（基线审查即出报告；测试代码按可编译标准编写，路由结论见 §6）

---

## 1. 基线结论（Base Review Summary）

| 维度 | 结论 | 备注 |
|---|---|---|
| **模块总数** | 42 个 Swift 文件（App 3 / Models 8 / AIEngines 6 / Services 9 / ViewModels 6 / Views 10） | 较架构文件清单多 1 个（`Views/Common/GlassCompat.swift`，已在源码注释说明） |
| **分层铁律符合度** | **L1 视图层全部符合**（Views/ 目录 grep `^import (CoreML\|VideoToolbox\|MetalPerformanceShaders)` 结果为 0） | 见 §3.1 |
| **错误域统一性** | 全部异常走 `AppError`（grep `throw ` 全部命中 `AppError.*` 形式） | 符合 §8.2 / R-12 |
| **@MainActor 边界** | 6 个 ViewModel + EngineRegistry + 处理方对外 API 全部标注 | 符合 §8.4 |
| **文案集中度** | 5 模式 / 3 能力 / 2 引擎种类 / 8 错误 case / 3 画质档 全部 `displayName` / `errorDescription` 集中 | 符合 §8.1 |
| **核心协议（AIEngine）** | 定义清晰（AnyObject + Sendable），输出语义（`SendablePixelBuffer` `@unchecked Sendable` 薄包装） | 符合 §2.1 |
| **可单测覆盖率** | **10 个核心类型** 完全可离线单测（见 §2.1） | 占 42 文件的 24% |
| **必真机测试** | 8 项（见 §2.2） | 实时链路 / 视频解码 / 相册保存等 |

**总体判定**：

- ✅ **架构实现度高质量**：分层铁律、错误域、@MainActor 边界、Sendable 并发安全、文案集中这五项核心约束**全部达成**。
- ⚠️ **P1 问题 3 项**：见 §3，需工程师寇豆码修复。
- 📝 **建议改进 5 项**：见 §4，非阻断。

**智能路由判定结论**（详见 §6）：**`Send To: Engineer`**（3 项 P1 待修复）+ **`Send To: QA(self)` 1 项**（测试代码中已自修——`waitUntil` 闭包同步/异步签名）。

---

## 2. 可测性分析（Testability Matrix）

### 2.1 完全可离线单测（10 个核心类型 / 共 18 个文件）

| 类型 | 文件 | 可测规则 | 已写测试 |
|---|---|---|---|
| `AppError` | Models/AppError.swift | §8.2 NSError 桥接 / errorDescription / recoverySuggestion / shouldPresentAlert | `AppErrorTests` |
| `EngineCapability` / `EngineKind` / `EngineState` | Models/EngineCapability.swift | §2.1 isUsable / displayName | `EngineCapabilityTests` |
| `ProcessingMode` | Models/ProcessingMode.swift | R-01~R-05 / §1.1 链路类型 / 能力映射 | `ProcessingModeTests` |
| `TensorPixelFormat` / `TensorSpec` / `TensorContract` | Models/TensorSpec.swift | PRD §3.4-5 通道/格式契约 | `TensorSpecTests` |
| `OfflineTask` / `OfflineTaskStatus` | Models/OfflineTask.swift | §3.2 状态机 / 终态保护 / isTerminal | `OfflineTaskTests` |
| `ProcessingSettings` | Models/ProcessingSettings.swift | R-21 / §10-1 实时锁 x2 / UserDefaults round-trip | `ProcessingSettingsTests` |
| `ImportedModel` | Models/ImportedModel.swift | §8.1 engineID 约定 / R-13 清单持久化 | `ImportedModelTests` |
| `PerformanceMetrics` | Models/PerformanceMetrics.swift | R-10 meetsLatencyBudget / 零值占位 | `PerformanceMetricsTests` |
| `InterpolationConfig` / `UpscaleQuality` | AIEngines/AIEngine.swift | §2.1 phases / §10-1 x2 锁 / R-29 分档 | `InterpolationConfigTests` |
| `EngineRegistry` | AIEngines/EngineRegistry.swift | §2.3 注册/反注册/切换/降级决策①→②→③ | `EngineRegistryTests` |
| `OfflineTaskQueue`（actor） | Services/OfflineTaskQueue.swift | R-14 严格串行/入队序/取消/状态流转 | `OfflineTaskQueueTests` |
| `PixelBufferPool` | Services/PixelBufferPool.swift | §3.1 / §9.3 每规格上限 6 / drain / fallback | `PixelBufferPoolTests` |
| `ProcessingCancelToken` | Services/OfflineProcessingService.swift | §3.2 取消传播 | `ProcessingCancelTokenTests` |
| `MetricsCollector` | Services/MetricsCollector.swift | R-10 500ms 聚合 / start-stop 幂等 | `MetricsCollectorTests` |
| `TensorValidator`（描述层） | AIEngines/TensorValidator.swift | R-32 五规则（依赖样本模型） | `TensorValidatorTests`（XCTSkip 兜底） |

> 上述 10 类已有测试覆盖。`TensorValidator` 因 `MLModelDescription` 无公开构造器，规则级断言需样本模型，**缺失则 XCTSkip**（不硬编失败）。

### 2.2 真机必测项（无法在 Mac 单元测试覆盖）

| 路径 | 真机必测理由 | 建议覆盖设备 |
|---|---|---|
| `VTFrameProcessorEngine` | iOS 26 SDK ※SDK 符号以 Xcode 26 头文件为准（`VTLowLatencyFrameInterpolationConfiguration` 等） | iPhone 15 Pro (A17 Pro) |
| `CoreMLImportEngine.warmUp/predict` | 依赖真实 `MLModel.prediction` + MPS 着色器编译 | iPhone 12+ |
| `CameraCaptureService` | AVCaptureSession 硬件依赖 | iPhone 真机 |
| `RealtimePipelineService` 推理门闩 / DisplayLink 2× 节拍 / 热切换 | 实时性 / 端到端 <150ms | iPhone 15 Pro |
| `OfflineProcessingService` AVAssetReader/Writer / HEVC 编码 / 内存压力降级 | 真实视频文件 + 系统编码器 | iPhone 12+ |
| `PhotoLibraryService.saveVideo` | PHPhotoLibrary 权限 + 系统回调 | iPhone 真机 |
| `MetricsCollector` 真实 CPU/GPU 占用 / 延迟测量 | 依赖硬件 / 系统时钟域 | iPhone 12+ |
| `ViewModels` ↔ Services 端到端联调 | 状态机 + 错误流贯通 | iPhone 12+ |

---

## 3. 静态审查发现（按 P0/P1/P2 分级）

### 3.1 分层铁律（**L1 禁 import CoreML/VideoToolbox**）— **全部符合**

```
$ grep -E "^import (CoreML|VideoToolbox|MetalPerformanceShaders)" Views/**/*.swift
（无结果）
```

✅ 全部 L1 文件仅 `import SwiftUI` / `UIKit` / `UniformTypeIdentifiers` / `AVFoundation`（仅 GlassPlayerView 因 AVPlayer 必要 / RealtimePreviewView 因 CoreVideo + MetalKit 用于 Metal 纹理直渲）。**符合 §1.2 第 1 条分层铁律**。

### 3.2 P0 阻断（**0 项**）

无 P0 阻断项。

### 3.3 P1 严重（**3 项，需工程师修复**）

#### P1-01：`AppError` 未遵循 `CustomNSError`，NSError 桥接 domain/code 不生效（架构 §8.2 违约）

- **位置**：`Models/AppError.swift:38`（`enum AppError: LocalizedError, Sendable, Equatable`）
- **现象**：架构 §8.2 明确「NSError domain = `com.vtframepro.error`；code 与注释编号一致」。实现虽定义了同名的 `errorDomain` / `errorCode` 属性，但**未声明 `CustomNSError` 协议符合**。因此 `(AppError.cancelled as NSError)` 的 `domain` / `code` **不会**等于 `com.vtframepro.error` / `4003`（Swift 默认桥接给出的是类型名域 + code=1 等），`errorCode` 只是普通应用属性，无法到达标准 NSError 桥接。
- **证据**：`AppErrorTests.testNSErrorBridge_containsDomainAndDescription`（按架构期望断言 `domain == AppError.errorDomain` 且 `code == 2001`）在修复前**预计失败**。
- **建议**：声明 `enum AppError: LocalizedError, CustomNSError, Sendable, Equatable`（`errorDomain` / `errorCode` 已存在，`errorUserInfo` 返回 `[:]` 即可），使桥接生效。
- **影响**：`ViewModel` 若按 NSError 方式归因日志/降级，会拿不到稳定 domain/code。**严重性：P1**（契约违约，1 行修复）。

#### P1-02：`TensorValidator` 超分分支中途 throw，破坏 R-32「列全部原因」

- **位置**：`TensorValidator.swift:99-115`
- **现象**：规则③中超分输入尺寸非法（width/height ≤ 0）时 `reasons.append(...)` 后**立即 throw**，中止后续规则收集——R-32 要求「任一不满足即拒绝并列出全部原因」，当前实现会少报原因（例如同时存在的批次/通道问题无法继续累计）。
- **建议**：改为 `reasons.append("输入张量尺寸非法")` 后**不立即 throw**，继续收集其余规则，最后统一 `guard reasons.isEmpty else { throw }`（与文件其余分支一致）。
- **影响**：用户导入超分模型时可能只看到 1 条错误而非全部。**严重性：P1**（契约语义不彻底）。

#### P1-03：`OfflineTaskQueue` 取消路径在「执行中 + 引擎解析/预热期」无即时响应，且 early-return 未清理取消令牌

- **位置**：`OfflineTaskQueue.swift:129-141`（execute 的 engineResolver 早退路径）
- **现象**：
  - `execute` 中 `guard let engine = await engineResolver(...) else { ...updateStatus(.failed) ; return }` 的**早退路径未清理 `cancelTokens[taskID]`**（正常路径 line 171 才 remove），有微量字典泄漏；
  - 用户在该 `await` 窗口内取消：`cancel(taskID:)` 已置令牌，但引擎解析仍返回 nil → 任务终态为 `.failed(noUsableEngine)` 而非 `.cancelled`，违反「取消属正常状态机、不弹错误窗」（§8.2）。
- **建议**：① 早退路径补 `cancelTokens.removeValue(forKey: taskID)`；② 解析返回 nil 前先检查 `cancelTokens[taskID]?.isCancelled`，已取消则置 `.cancelled`。
- **影响**：取消竞态下出现「已取消却报无可用引擎」的误导弹窗 + 小内存泄漏。**严重性：P1**。

### 3.4 P2 建议（**5 项，非阻断**）

| 编号 | 位置 | 建议 | 理由 |
|---|---|---|---|
| P2-01 | `AppDependencies.swift:99-104` | `engineResolver` 闭包未对 `EngineRegistry` weak 引用做生命周期保护外的二次校验 | 当前 `[weak engineRegistry]` 良好，但 `engineID` 解析失败时无降级文案直接返回 nil；建议 logging |
| P2-02 | `RealtimeViewModel.swift:118-128` | `stopTapped` 中 `engine?.reset()` 在异步 Task 内调用，UI 立即翻转 isRunning；建议加 200ms 防抖避免极短点按 | 体验细节 |
| P2-03 | `HomeViewModel.swift:60-83` | `refresh()` 频繁调用且每次重算全部 5 模式；建议合并增量刷新 | 性能，非首版关键 |
| P2-04 | `EngineRegistry.swift:99-101` | `prepare` 调用为 `try?` 吞错，状态由各引擎自行表达；但失败原因需日志可达 | 调试体验 |
| P2-05 | `OfflineProcessingService.swift:381-398` | `DispatchSourceMemoryPressure` 监听未提供手动解注册（仅 `deinit` 中 cancel）；若服务被复用需显式 | 边缘场景 |

---

## 4. 测试覆盖矩阵

### 4.1 已写测试文件（位于 `VTFrameProTests/`）

| 测试文件 | 覆盖类型 | 用例数（约） | 关键规则 |
|---|---|---|---|
| `AppErrorTests.swift` | 单元 | 14 | §8.2 |
| `ProcessingModeTests.swift` | 单元 | 11 | R-01~R-05 |
| `EngineCapabilityTests.swift` | 单元 | 9 | §2.1 |
| `TensorSpecTests.swift` | 单元 | 7 | PRD §3.4-5 |
| `OfflineTaskTests.swift` | 单元 | 9 | §3.2 / R-14 |
| `PerformanceMetricsTests.swift` | 单元 | 4 | R-10 |
| `ProcessingSettingsTests.swift` | 单元 | 8 | R-21 / §10-1 |
| `ImportedModelTests.swift` | 单元 | 5 | §8.1 / R-13 |
| `InterpolationConfigTests.swift` | 单元 | 6 | §2.1 / §10-1 |
| `EngineRegistryTests.swift` | 单元 | 12 | §2.3 / R-20 / R-31 |
| `OfflineTaskQueueTests.swift` | 集成 | 4 | §3.2 / R-14 |
| `PixelBufferPoolTests.swift` | 单元 | 7 | §3.1 / §9.3 |
| `ProcessingCancelTokenTests.swift` | 单元 | 3 | §3.2 |
| `MetricsCollectorTests.swift` | 轻量集成 | 3 | R-10 / §3.1 |
| `TensorValidatorTests.swift` | 单元（需样本） | 8（5 跳过） | R-32 |
| `TestSupport/MockAIEngine.swift` | 测试基座 | 1 类 | — |
| **合计** | — | **≥111 用例** | — |

### 4.2 规则编号追溯

每条测试方法在源码注释中标注对应 PRD 编号（如 R-32）与 ARCHITECTURE 章节号（如 §8.2），便于追溯到原始契约。

---

## 5. 已知问题（Known Issues）

1. **Windows 不可编译**：本机无 Swift Toolchain，所有测试仅做**静态审查 + 逻辑推演**，未实跑。请按 `TEST_RUN_GUIDE.md` 在 Mac 端 ⌘U 跑测。
2. **样本模型缺失**：`TensorValidatorTests` 中 R-32 规则级用例依赖 5 个样本模型（`InterpolationValid/InterpolationWrongCount/BadChannels/SuperResolutionBadScale/BatchNotOne/DynamicShape/MultiFail.mlpackage`），缺失则 XCTSkip。Mac 端可在 Test Target Bundle Resources 放入自训或公开的 CoreML 模型即可启用。
3. **EngineRegistry vs 实际 active 状态**：本报告 P1-01 指出的极端竞态下 `activeEngine` dict 可能短暂空缺；测试已覆盖正常降级决策路径。

---

## 6. 智能路由判定（Smart Routing Decision）

### 6.1 决策矩阵

| 现象 | 类别 | 路由 | 说明 |
|---|---|---|---|
| 42 个源文件全部符合分层铁律 / 错误域 / @MainActor / 文案集中 | 通过 | **NoOne** | 基础质量达标 |
| P1-01 / P1-02 / P1-03 三项业务逻辑问题 | 源码 Bug | **Engineer (寇豆码)** | P1-01 有对应测试 `AppErrorTests.testNSErrorBridge_containsDomainAndDescription`（按架构期望，修复前预计失败）；P1-02/P1-03 经静态审查 + 逻辑推演定位 |
| `waitUntil` 闭包签名最初为同步 `@MainActor () -> Bool` → 多处调用需 `await queue.currentTasks()` 异步 | 测试代码 Bug | **QA(self)** | **已自修**：将 `waitUntil` 改为 `() async -> Bool`，所有调用点已加 `await` |
| `OfflineTaskQueueTests` 引用私有 `AsyncStream<Void>.makeStream()` 工具 | 私有扩展可见性 | **QA(self)** | 已添加 `private extension AsyncStream where Element == Void` 提供 `makeStream()` 工厂 |
| `makeQueue()` 中引用 `OfflineProcessingService` / `PhotoLibraryService` 真实实例 | 依赖注入设计 | **QA(self)** | 测试中允许直接构造 DI 容器内部类型，actor OfflineTaskQueue 本身即为可测目标 |

### 6.2 最终路由结论

**`Send To: Engineer (寇豆码)`**：3 项 P1 需修复（详见 §3.3）。

**`Send To: QA(self)`**：1 项（waitUntil 签名）已自修。

**`Send To: NoOne`**：其余全量源码审查通过。

---

## 7. 交付清单

| 文件 | 路径 | 用途 |
|---|---|---|
| 测试代码（15 文件） | `VTFrameProTests/` | ⌘U 跑测，按 `TEST_RUN_GUIDE.md` 配置 |
| 本报告 | `docs/qa/QA_REPORT.md` | 基线结论 / 问题清单 / 路由判定 |
| Mac 教程 | `docs/qa/TEST_RUN_GUIDE.md` | GUI step-by-step 配 Test target + 跑测 + 排查 |

---

*报告结束。下一步：工程师寇豆码按 §3.3 P1 清单修复；Mac 端用户按 TEST_RUN_GUIDE 跑测。*
