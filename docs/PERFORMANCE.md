# VTFramePro 性能与内存风险分析

> 对应 ARCHITECTURE.md §9 扩充。数据为设计预估量级，最终以真机 Instruments 实测为准。

## 1. 瓶颈分析

### 1.1 实时链路（720p 上限，预算 <150ms）

| 瓶颈 | 机理 | 影响面 | 量级估算 |
|---|---|---|---|
| ANE/GPU 竞争 | 串联模式下插值与两级超分争抢 ANE/GPU；预览上屏渲染同抢 GPU | 实时补帧+超分（R-03） | 单帧插值 ≈15–25ms，x2 超分（低延迟档）≈10–20ms/帧 |
| 内存带宽 | 720p BGRA 单帧 ≈ 3.7MB；x2 后 ≈ 14.7MB；30fps 输入 + 60fps 输出带宽 >1.7GB/s | 实时超分/串联 | 连续高带宽易触发热降频 |
| 插值+超分双重开销 | 每输出 1 帧逻辑需 1 次插值 + 最多 2 次超分 | 串联模式延迟预算 | 合计 35–65ms/帧对，逼近 2× 节拍 16.7ms 的倍帧预算 |
| VT 会话冷启动 | 首次 `startSession` 触发系统模型加载/下载 | 首次进入实时页 | 可达数百 ms（预热兜底，见 §2.4） |

**结论**：串联模式是预算最紧的路径。720p30 下 x2 补帧已占满预算（§10-1 拍板锁死 x2）；串联时以画质档位与热降档兜底。

### 1.2 离线链路

| 瓶颈 | 机理 | 缓解 |
|---|---|---|
| 4K 素材单帧内存 | 4K BGRA ≈ 33MB/帧，超分输出 ≈ 133MB/帧 | 严格「解码一帧→处理→写入→释放」，帧不驻留 |
| 编码回压 | HEVC 编码慢于处理时 writer 输入侧堆积 | `isReadyForMoreMediaData` 背压等待（挂起而非排队） |
| 长时间任务热积累 | 连续 ANE/GPU 满载 | 分批 autoreleasepool 间自然喘息；内存水位中止兜底 |

## 2. ANE/GPU 优化策略

1. **零拷贝全链路**：采集 buffer 直通引擎（不复制像素）；引擎输出写入 `CVPixelBufferPool`（每规格上限 6）；上屏经 `CIImage(cvPixelBuffer:)` + `CIContext(mtlDevice:)` 直渲 drawable 纹理；CoreML 图像输出经 `MLPredictionOptions.outputBackings` 直写池化 buffer。全链路像素数据零 CPU 拷贝。
2. **GPU 张量转换**：导入模型的 32BGRA ↔ RGB float 转换由 MPS（`MPSImageConversion` 归一化）+ 轻量打包/解包 kernel 完成，无 CPU 逐像素循环；仅 `MLMultiArray` 进出各一次 memcpy（一次性，非逐元素）。
3. **画质档位**（`ProcessingSettings.realtimeQualityTier`）：性能档在串联模式自动关超分级；均衡（默认）/画质档控制超分开关。
4. **热降档**：`ProcessInfo.thermalState` 达 `.serious` 起，串联模式自动退级（关超分）并 Toast 提示（R-24 首版范围）。
5. **预热**：引擎 `prepare()` 内黑帧推理一次，消除首帧抖动击穿 150ms 预算；VT 预热会话在 `prepare` 时即建立（系统模型加载前置）。
6. **模型常驻与热切换缓冲**：新引擎预热完成前旧引擎继续出帧，切换零断帧。

## 3. 内存风险与 OOM 防线（R-15）

| 防线 | 阈值/机制 | 代码位置 |
|---|---|---|
| 内存水位 | `os_proc_available_memory()` 每帧采样，**<512MB 中止离线任务**（`.outOfMemory`） | `OfflineProcessingService` |
| 分批大小 | 帧级作用域 + 同步段 autoreleasepool；告警后批大小 15→8 | `OfflineProcessingService` |
| 内存压力分级 | `DispatchSourceMemoryPressure`：warning → drain 池 + 缩批；critical → 下一检查点中止 | `OfflineProcessingService` |
| 池上限 | `PixelBufferPool` 每规格上限 6（超额回落独立分配不阻塞） | `PixelBufferPool` |
| 帧不驻留 | 离线严格逐帧流转；实时配对仅保留 1 帧历史 | 两条链路 |
| 双引擎同驻 | 串联降档时 `reset()` 释放超分级资源 | `RealtimePipelineService` |
| 临时文件 | 统一 `temporaryDirectory/vtframepro/`；任务失败/取消必删；启动清扫残留；写前检查磁盘 ≥ 输出估算 2 倍 | `OfflineProcessingService` |
| 背压三层 | 采集 `.bufferingNewest(1)` + 推理门闩（1 次在飞，latest-frame-wins）+ `alwaysDiscardsLateVideoFrames` | 采集/流水线 |

## 4. 指标采集口径（§10-3 分级呈现）

| 指标 | 来源 | 精度 |
|---|---|---|
| FPS | DisplayLink 上屏计数 1s 滑动窗口 | 精确 |
| 端到端延迟 | 采集 PTS（mach 时钟域）与上屏时刻差滑动平均 | 精确 |
| CPU | `task_threads` + `thread_info(THREAD_BASIC_INFO)` | 精确（公开 Darwin API） |
| 内存 | `task_info(TASK_VM_INFO).phys_footprint` | 精确 |
| GPU/ANE | 推理耗时占帧预算比 | **估算**（UI 已标注；IOReport 私有禁用） |
| 热状态 | `ProcessInfo.thermalState` | 精确 |

## 5. 后续优化方向（非首版）

- 串联模式超分级改投 Metal 轻量放大（LANCZOS）替代 AI 超分，换取预算内稳定 60fps；
- VT 光流预算（`VTOpticalFlowConfiguration`）复用降低插值成本；
- x4 补帧离线开放（`InterpolationConfig.factor` 已预留）；
- 若 iOS 27 开放 GPU/ANE 性能计数公开 API，平滑切换估算口径。
