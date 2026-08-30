//
//  CoreMLImportEngine.swift
//  VTFramePro
//
//  CoreML + MPS 引擎实现（L4 AI 引擎协议层）。
//  对应 ARCHITECTURE.md §2.4（R-27）：每个已导入并校验通过的模型一个实例。
//
//  像素格式与张量转换在 GPU 完成（§2.4 / §9.2-1）：
//  - 输入：CVPixelBuffer(32BGRA) → MPSImageConversion 色彩/归一化 →
//    自定义轻量 kernel 打包为 MLMultiArray（平面 NCHW 或交错 NHWC，随模型约束）；
//  - 输出：image 类型经 MLPredictionOptions.outputBackings 直写池化 buffer（零拷贝）；
//    multiArray 类型经 kernel 解包 + MPSImageConversion 写回池化 buffer。
//  全程无 CPU 逐像素循环；MLModel 实例不离开本文件（§1.2 第 3 条）。
//

import Foundation
import Accelerate
import CoreML
import CoreVideo
import Metal
import MetalPerformanceShaders
import OSLog

/// 用户导入 CoreML 模型引擎。
///
/// - `capabilities` 取自导入时声明用途（§2.4）；
/// - `prepare()` 内懒加载 MLModel（computeUnits = .all，ANE+GPU 自动调度）+ 黑帧预热；
/// - 线程：`@unchecked Sendable`，MLModel 引用与 Metal 资源由 `stateLock` 保护，
///   推理调用在调用方并发域执行（MLModel.prediction 为同步阻塞调用，§8.4）。
final class CoreMLImportEngine: AIEngine, @unchecked Sendable {

    // MARK: - AIEngine 标识

    var engineID: String { descriptor.engineID }
    var displayName: String { descriptor.displayName }
    let kind: EngineKind = .coreMLImported
    var capabilities: Set<EngineCapability> { [descriptor.declaredKind] }

    // MARK: - 状态

    private(set) var state: EngineState {
        get { stateLock.withLock { _state } }
        set { stateLock.withLock { _state = newValue } }
    }
    let stateUpdates: AsyncStream<EngineState>

    // MARK: - 依赖与配置

    /// 模型元数据（含张量契约）。
    private let descriptor: ImportedModel
    /// 沙盒内 mlpackage URL。
    private let modelURL: URL
    /// 输出帧池。
    private let pixelBufferPool: PixelBufferPool

    // MARK: - 推理资源（锁保护）

    private let stateLock = NSLock()
    private var _state: EngineState = .checking
    private let stateContinuation: AsyncStream<EngineState>.Continuation
    /// 已加载模型（prepare 后非空；绝不离开 L4）。
    private var model: MLModel?
    /// GPU 张量转换器（prepare 后非空）。
    private var converter: PixelTensorConverter?
    /// 已编译模型缓存目录（Application Support/CompiledModels）。
    private let compiledCacheURL: URL
    private let logger = Logger(subsystem: "com.vtframepro", category: "engine")

    // MARK: - 初始化

    /// - Parameters:
    ///   - descriptor: 模型元数据。
    ///   - pixelBufferPool: 输出帧池。
    ///   - modelURL: 沙盒内 mlpackage 路径。
    init(descriptor: ImportedModel, pixelBufferPool: PixelBufferPool, modelURL: URL) {
        self.descriptor = descriptor
        self.pixelBufferPool = pixelBufferPool
        self.modelURL = modelURL
        self.compiledCacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CompiledModels", directoryHint: .isDirectory)
        var continuation: AsyncStream<EngineState>.Continuation!
        self.stateUpdates = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
    }

    deinit {
        stateContinuation.finish()
    }

    // MARK: - AIEngine.prepare

    /// 懒加载 MLModel + 黑帧预热（幂等）。
    ///
    /// 流程：模型文件存在性 → 编译缓存（mlpackage → mlmodelc）→ 加载
    /// （computeUnits = .all）→ 黑帧推理一次 → .ready。
    func prepare(for capability: EngineCapability) async throws {
        // 幂等：已就绪直接返回。
        if state.isUsable { return }
        guard capabilities.contains(capability) else {
            throw AppError.engineUnsupported(
                detail: "\(displayName) 不支持\(capability.displayName)")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            emit(.modelNotInstalled)
            throw AppError.ioFailed(underlying: "模型文件不存在：\(modelURL.lastPathComponent)")
        }
        do {
            let compiledURL = try compileIfNeeded()
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all // ANE+GPU 自动调度（§2.4）
            let loaded = try MLModel(contentsOf: compiledURL, configuration: configuration)
            let gpuConverter = try PixelTensorConverter()
            stateLock.withLock {
                model = loaded
                converter = gpuConverter
            }
            try warmUp()
            emit(.ready)
        } catch let error as AppError {
            throw error
        } catch {
            logger.error("模型加载失败: \(error.localizedDescription)")
            throw AppError.ioFailed(underlying: "模型加载失败：\(error.localizedDescription)")
        }
    }

    /// 黑帧预热（消除首帧抖动击穿 150ms 预算，§9.2-4）。
    ///
    /// 以契约声明的输入尺寸生成全黑帧，跑一遍完整推理路径。
    func warmUp() throws {
        guard let model = stateLock.withLock({ model }) else { return }
        let contract = descriptor.tensorContract
        guard let firstInput = contract.inputs.first else { return }
        let width = max(firstInput.width, 16)
        let height = max(firstInput.height, 16)
        let blackA = try pixelBufferPool.acquire(width: width, height: height)
        let blackB = try pixelBufferPool.acquire(width: width, height: height)
        // 预热路径与真实推理一致：按声明用途走一次。
        if descriptor.declaredKind == .frameInterpolation {
            _ = try interpolateSync(model: model, frame0: blackA, frame1: blackB, timestep: 0.5)
        } else {
            _ = try upscaleSync(model: model, frame: blackA, scale: 2)
        }
    }

    // MARK: - AIEngine.interpolate

    func interpolate(frame0: CVPixelBuffer,
                     frame1: CVPixelBuffer,
                     at timestep: Float,
                     capability capabilityConfig: InterpolationConfig) async throws -> CVPixelBuffer {
        guard let model = stateLock.withLock({ model }) else {
            throw AppError.inferenceFailed(underlying: "模型未加载，请先 prepare")
        }
        do {
            return try interpolateSync(model: model, frame0: frame0, frame1: frame1, timestep: timestep)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.inferenceFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - AIEngine.upscale

    func upscale(_ frame: CVPixelBuffer,
                 scale: Int,
                 quality qualityConfig: UpscaleQuality) async throws -> CVPixelBuffer {
        guard let model = stateLock.withLock({ model }) else {
            throw AppError.inferenceFailed(underlying: "模型未加载，请先 prepare")
        }
        do {
            return try upscaleSync(model: model, frame: frame, scale: scale)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.inferenceFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - AIEngine.reset

    /// 释放 MLModel 与 GPU 资源（内存告警/引擎切走时调用，幂等）。
    func reset() async {
        stateLock.withLock {
            model = nil
            converter = nil
        }
        // 释放后回到未安装态，下次使用需重新 prepare。
        emit(.modelNotInstalled)
        logger.notice("CoreML 引擎资源已释放: \(self.descriptor.displayName)")
    }

    // MARK: - 私有：补帧推理

    /// 补帧同步推理（调用方并发域执行）。
    private func interpolateSync(model: MLModel,
                                 frame0: CVPixelBuffer,
                                 frame1: CVPixelBuffer,
                                 timestep: Float) throws -> CVPixelBuffer {
        let description = model.modelDescription
        let frames = [frame0, frame1]

        // 组装输入：图像类输入按名称序喂两帧；非标量图像输入（如 timestep）喂相位值。
        var inputs: [String: MLFeatureValue] = [:]
        let imageInputNames = description.inputDescriptionsByName
            .filter { TensorValidatorBridge.isImageLike($0.value) }
            .sorted { $0.key < $1.key }
            .map { $0.key }
        for (index, name) in imageInputNames.enumerated() {
            let frame = frames[min(index, frames.count - 1)]
            inputs[name] = try featureValue(for: description.inputDescriptionsByName[name]!,
                                            frame: frame)
        }
        for (name, feature) in description.inputDescriptionsByName
        where !TensorValidatorBridge.isImageLike(feature) {
            // 非图像输入（插值相位标量）：按类型喂 timestep。
            inputs[name] = try scalarFeatureValue(for: feature, value: timestep)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        return try predict(model: model, provider: provider)
    }

    // MARK: - 私有：超分推理

    /// 超分同步推理（调用方并发域执行）。
    private func upscaleSync(model: MLModel,
                             frame: CVPixelBuffer,
                             scale: Int) throws -> CVPixelBuffer {
        let description = model.modelDescription
        guard let inputName = description.inputDescriptionsByName
            .filter({ TensorValidatorBridge.isImageLike($0.value) })
            .sorted(by: { $0.key < $1.key })
            .first?.key,
              let inputFeature = description.inputDescriptionsByName[inputName] else {
            throw AppError.inferenceFailed(underlying: "模型无图像输入")
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputName: featureValue(for: inputFeature, frame: frame)
        ])
        return try predict(model: model, provider: provider)
    }

    // MARK: - 私有：统一预测出口

    /// 执行预测并取出输出帧（池化分配）。
    ///
    /// 输出路径：
    /// - image 类型：优先 `outputBackings` 直写池化 buffer（零拷贝）；
    /// - multiArray 类型：GPU 解包写回池化 buffer。
    private func predict(model: MLModel, provider: MLDictionaryFeatureProvider) throws -> CVPixelBuffer {
        let description = model.modelDescription
        guard let outputName = description.outputDescriptionsByName
            .filter({ TensorValidatorBridge.isImageLike($0.value) })
            .sorted(by: { $0.key < $1.key })
            .first?.key,
              let outputFeature = description.outputDescriptionsByName[outputName] else {
            throw AppError.inferenceFailed(underlying: "模型无图像输出")
        }

        // 输出尺寸：image 约束或契约声明。
        let (outWidth, outHeight) = outputDimensions(of: outputFeature)
        let destination = try pixelBufferPool.acquire(width: outWidth, height: outHeight)

        switch outputFeature.type {
        case .image:
            // 零拷贝路径：CoreML 直写池化 buffer（iOS 16+ outputBackings）。
            let options = MLPredictionOptions()
            options.outputBackings = [outputName: MLFeatureValue(pixelBuffer: destination)]
            _ = try model.prediction(from: provider, options: options)
            return destination

        case .multiArray:
            let result = try model.prediction(from: provider)
            guard let multiArray = result.featureValue(for: outputName)?.multiArrayValue else {
                throw AppError.inferenceFailed(underlying: "输出张量缺失")
            }
            guard let converter = stateLock.withLock({ converter }) else {
                throw AppError.inferenceFailed(underlying: "GPU 转换器未就绪")
            }
            try converter.writeToPixelBuffer(multiArray: multiArray, destination: destination)
            return destination

        default:
            throw AppError.inferenceFailed(underlying: "输出类型不支持")
        }
    }

    // MARK: - 私有：特征值构造

    /// 按输入特征类型构造特征值（image 直传 buffer / multiArray 走 GPU 转换）。
    private func featureValue(for feature: MLFeatureDescription,
                              frame: CVPixelBuffer) throws -> MLFeatureValue {
        switch feature.type {
        case .image:
            // CoreML 内部完成像素格式转换（GPU），直传零拷贝。
            return MLFeatureValue(pixelBuffer: frame)
        case .multiArray:
            guard let constraint = feature.multiArrayConstraint,
                  let converter = stateLock.withLock({ converter }) else {
                throw AppError.inferenceFailed(underlying: "张量约束/转换器缺失")
            }
            let multiArray = try converter.makeInputMultiArray(from: frame, constraint: constraint)
            return MLFeatureValue(multiArray: multiArray)
        default:
            throw AppError.inferenceFailed(underlying: "输入类型不支持：\(feature.name)")
        }
    }

    /// 非标量图像输入（插值相位）特征值。
    private func scalarFeatureValue(for feature: MLFeatureDescription,
                                    value: Float) throws -> MLFeatureValue {
        switch feature.type {
        case .multiArray:
            guard let constraint = feature.multiArrayConstraint else {
                throw AppError.inferenceFailed(underlying: "标量张量约束缺失")
            }
            let array = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
            array[0] = NSNumber(value: value)
            return MLFeatureValue(multiArray: array)
        case .double:
            return MLFeatureValue(double: Double(value))
        case .int64:
            return MLFeatureValue(int64: Int64(value))
        default:
            throw AppError.inferenceFailed(underlying: "标量输入类型不支持：\(feature.name)")
        }
    }

    /// 输出尺寸推断（image 约束优先，回落契约声明）。
    private func outputDimensions(of feature: MLFeatureDescription) -> (Int, Int) {
        if let constraint = feature.imageConstraint, constraint.pixelsWide > 0 {
            return (constraint.pixelsWide, constraint.pixelsHigh)
        }
        if let output = descriptor.tensorContract.outputs.first {
            return (output.width, output.height)
        }
        // 兜底：契约缺失时按输入 2 倍（首版超分约定）。
        let input = descriptor.tensorContract.inputs.first
        return ((input?.width ?? 320) * 2, (input?.height ?? 240) * 2)
    }

    // MARK: - 私有：编译缓存

    /// mlpackage → mlmodelc 编译（带持久缓存，避免每次启动重编译）。
    private func compileIfNeeded() throws -> URL {
        let fileManager = FileManager.default
        let cachedURL = compiledCacheURL.appending(path: "\(descriptor.id.uuidString).mlmodelc", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        try fileManager.createDirectory(at: compiledCacheURL, withIntermediateDirectories: true)
        // MLModel.compileModel 输出到系统临时目录，再移入持久缓存。
        let temporaryCompiled = try MLModel.compileModel(at: modelURL)
        if fileManager.fileExists(atPath: cachedURL.path) {
            try fileManager.removeItem(at: cachedURL)
        }
        try fileManager.moveItem(at: temporaryCompiled, to: cachedURL)
        logger.notice("模型编译完成: \(self.descriptor.displayName)")
        return cachedURL
    }

    // MARK: - 私有：状态发射

    private func emit(_ newState: EngineState) {
        state = newState
        stateContinuation.yield(newState)
        logger.notice("CoreML 引擎状态 [\(self.descriptor.displayName)]: \(newState.displayName)")
    }
}

// MARK: - 校验器桥接（复用 TensorValidator 的特征判定，避免重复实现）

/// TensorValidator 的特征判定对引擎内部可见的桥接（同层复用，不跨层）。
enum TensorValidatorBridge {
    /// 判定特征是否图像类（与 TensorValidator 规则一致）。
    static func isImageLike(_ feature: MLFeatureDescription) -> Bool {
        switch feature.type {
        case .image:
            return true
        case .multiArray:
            guard let constraint = feature.multiArrayConstraint else { return false }
            return constraint.shape.count >= 3
        default:
            return false
        }
    }
}

// MARK: - GPU 张量转换器

/// CVPixelBuffer ↔ MLMultiArray 的 GPU 转换器。
///
/// 管线（§2.4 MPS on GPU）：
/// - 输入：BGRA8 纹理 --(MPSImageConversion 归一化)--> RGBA float32 纹理
///   --(自定义打包 kernel)--> MTLBuffer --> memcpy 至 MLMultiArray；
/// - 输出：MLMultiArray --> MTLBuffer --(解包 kernel)--> RGBA float32 纹理
///   --(MPSImageConversion)--> BGRA8 池化 buffer 纹理。
/// 打包/解包 kernel 支持平面（NCHW）与交错（NHWC）两种内存布局，随模型约束切换。
final class PixelTensorConverter: @unchecked Sendable {

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private let packPipeline: any MTLComputePipelineState
    private let unpackPipeline: any MTLComputePipelineState
    private let conversion: MPSImageConversion

    /// Metal 着色语言源码（运行时编译，无第三方依赖、无私有 API）。
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // 交错 RGBA float 纹理 → 张量缓冲（isPlanar=1: NCHW 平面；=0: NHWC 交错）。
    kernel void packToTensor(texture2d<float, access::read> src [[texture(0)]],
                             device float* dst [[buffer(0)]],
                             constant int& channels [[buffer(1)]],
                             constant int& isPlanar [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint w = src.get_width();
        uint h = src.get_height();
        if (gid.x >= w || gid.y >= h) { return; }
        float4 px = src.read(gid);
        uint pixelIndex = gid.y * w + gid.x;
        float values[4] = { px.r, px.g, px.b, px.a };
        for (int c = 0; c < channels; c++) {
            if (isPlanar == 1) {
                dst[c * w * h + pixelIndex] = values[c];
            } else {
                dst[pixelIndex * channels + c] = values[c];
            }
        }
    }

    // 张量缓冲 → 交错 RGBA float 纹理。
    kernel void unpackFromTensor(device const float* src [[buffer(0)]],
                                 constant int& channels [[buffer(1)]],
                                 constant int& isPlanar [[buffer(2)]],
                                 texture2d<float, access::write> dst [[texture(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        uint w = dst.get_width();
        uint h = dst.get_height();
        if (gid.x >= w || gid.y >= h) { return; }
        uint pixelIndex = gid.y * w + gid.x;
        float4 px;
        px.r = (isPlanar == 1) ? src[pixelIndex] : src[pixelIndex * channels];
        px.g = (channels > 1) ? ((isPlanar == 1) ? src[w * h + pixelIndex] : src[pixelIndex * channels + 1]) : px.r;
        px.b = (channels > 2) ? ((isPlanar == 1) ? src[2 * w * h + pixelIndex] : src[pixelIndex * channels + 2]) : px.r;
        px.a = (channels > 3) ? ((isPlanar == 1) ? src[3 * w * h + pixelIndex] : src[pixelIndex * channels + 3]) : 1.0;
        dst.write(px, gid);
    }
    """

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw AppError.engineUnsupported(detail: "Metal 设备不可用")
        }
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw AppError.engineUnsupported(detail: "Metal 纹理缓存创建失败")
        }
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let packFunction = library.makeFunction(name: "packToTensor"),
              let unpackFunction = library.makeFunction(name: "unpackFromTensor"),
              let packPipeline = try? device.makeComputePipelineState(function: packFunction),
              let unpackPipeline = try? device.makeComputePipelineState(function: unpackFunction) else {
            throw AppError.engineUnsupported(detail: "Metal 着色器编译失败")
        }
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = cache
        self.packPipeline = packPipeline
        self.unpackPipeline = unpackPipeline
        // MPS 色彩/归一化转换（BGRA8 ↔ RGBA float32，sRGB 恒等空间）。
        self.conversion = MPSImageConversion(device: device)
    }

    // MARK: 输入路径：CVPixelBuffer → MLMultiArray

    /// 按模型约束生成输入张量（GPU 转换 + 一次内存拷贝）。
    func makeInputMultiArray(from pixelBuffer: CVPixelBuffer,
                             constraint: MLMultiArrayConstraint) throws -> MLMultiArray {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let shape = constraint.shape.map(\.intValue)
        let (channels, isPlanar) = try Self.tensorLayout(of: shape)

        // ① BGRA8 → RGBA float32（MPS 归一化，GPU）。
        let sourceTexture = try texture(from: pixelBuffer, pixelFormat: .bgra8Unorm)
        let floatTexture = try makeFloatTexture(width: width, height: height)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw AppError.inferenceFailed(underlying: "Metal command buffer 创建失败")
        }
        conversion.encode(commandBuffer: commandBuffer,
                          sourceTexture: sourceTexture,
                          destinationTexture: floatTexture)

        // ② RGBA float32 → 张量缓冲（打包 kernel，GPU）。
        let elementCount = channels * width * height
        guard let tensorBuffer = device.makeBuffer(length: elementCount * MemoryLayout<Float>.stride,
                                                   options: .storageModeShared) else {
            throw AppError.inferenceFailed(underlying: "张量缓冲分配失败")
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw AppError.inferenceFailed(underlying: "Metal compute encoder 创建失败")
        }
        var channelsValue = channels
        var planarValue = isPlanar ? 1 : 0
        encoder.setComputePipelineState(packPipeline)
        encoder.setTexture(floatTexture, index: 0)
        encoder.setBuffer(tensorBuffer, offset: 0, index: 0)
        encoder.setBytes(&channelsValue, length: MemoryLayout<Int>.stride, index: 1)
        encoder.setBytes(&planarValue, length: MemoryLayout<Int>.stride, index: 2)
        dispatchThreads(encoder: encoder, pipeline: packPipeline, width: width, height: height)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // ③ 拷贝进 MLMultiArray（一次性 memcpy，非逐像素）。
        let multiArray = try MLMultiArray(shape: constraint.shape, dataType: .float32)
        memcpy(multiArray.dataPointer, tensorBuffer.contents(),
               elementCount * MemoryLayout<Float>.stride)
        return multiArray
    }

    // MARK: 输出路径：MLMultiArray → CVPixelBuffer

    /// 将输出张量写回池化 buffer（GPU 解包 + MPS 格式转换）。
    func writeToPixelBuffer(multiArray: MLMultiArray,
                            destination: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(destination)
        let height = CVPixelBufferGetHeight(destination)
        let shape = multiArray.shape.map(\.intValue)
        let (channels, isPlanar) = try Self.tensorLayout(of: shape)
        let elementCount = channels * width * height
        guard multiArray.count >= elementCount else {
            throw AppError.inferenceFailed(underlying: "输出张量尺寸与目标帧不匹配")
        }

        // ① MLMultiArray → MTLBuffer（一次性 memcpy）。
        guard let tensorBuffer = device.makeBuffer(length: elementCount * MemoryLayout<Float>.stride,
                                                   options: .storageModeShared) else {
            throw AppError.inferenceFailed(underlying: "张量缓冲分配失败")
        }
        // float16 输出需先转 float32（Accelerate 批量转换，非逐像素循环）。
        if multiArray.dataType == .float16 {
            vImageConvert_Planar16FtoPlanarF(
                multiArray.dataPointer,
                tensorBuffer.contents(),
                vImagePixelCount(elementCount)
            )
        } else {
            memcpy(tensorBuffer.contents(), multiArray.dataPointer,
                   elementCount * MemoryLayout<Float>.stride)
        }

        // ② 张量缓冲 → RGBA float32 纹理（解包 kernel，GPU）。
        let floatTexture = try makeFloatTexture(width: width, height: height)
        let destinationTexture = try texture(from: destination, pixelFormat: .bgra8Unorm)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw AppError.inferenceFailed(underlying: "Metal command buffer 创建失败")
        }
        var channelsValue = channels
        var planarValue = isPlanar ? 1 : 0
        encoder.setComputePipelineState(unpackPipeline)
        encoder.setBuffer(tensorBuffer, offset: 0, index: 0)
        encoder.setBytes(&channelsValue, length: MemoryLayout<Int>.stride, index: 1)
        encoder.setBytes(&planarValue, length: MemoryLayout<Int>.stride, index: 2)
        encoder.setTexture(floatTexture, index: 0)
        dispatchThreads(encoder: encoder, pipeline: unpackPipeline, width: width, height: height)
        encoder.endEncoding()

        // ③ RGBA float32 → BGRA8 池化 buffer（MPS，GPU）。
        conversion.encode(commandBuffer: commandBuffer,
                          sourceTexture: floatTexture,
                          destinationTexture: destinationTexture)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: 私有：纹理工具

    /// 从 CVPixelBuffer 建 Metal 纹理（CVMetalTextureCache 零拷贝）。
    private func texture(from pixelBuffer: CVPixelBuffer,
                         pixelFormat: MTLPixelFormat) throws -> any MTLTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache!, pixelBuffer, nil, pixelFormat, width, height, 0, &textureRef)
        guard status == kCVReturnSuccess, let textureRef,
              let texture = CVMetalTextureGetTexture(textureRef) else {
            throw AppError.inferenceFailed(underlying: "Metal 纹理创建失败")
        }
        return texture
    }

    /// 申请 RGBA float32 中间纹理。
    private func makeFloatTexture(width: Int, height: Int) throws -> any MTLTexture {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw AppError.inferenceFailed(underlying: "中间纹理分配失败")
        }
        return texture
    }

    /// 计算线程组派发。
    private func dispatchThreads(encoder: any MTLComputeCommandEncoder,
                                 pipeline: any MTLComputePipelineState,
                                 width: Int, height: Int) {
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
    }

    /// 解析张量布局：返回 (channels, isPlanar)。
    static func tensorLayout(of shape: [Int]) throws -> (Int, Bool) {
        switch shape.count {
        case 4:
            if [3, 4].contains(shape[1]) { return (shape[1], true) }  // NCHW
            if [3, 4].contains(shape[3]) { return (shape[3], false) } // NHWC
        case 3:
            if [3, 4].contains(shape[0]) { return (shape[0], true) }  // CHW
            if [3, 4].contains(shape[2]) { return (shape[2], false) } // HWC
        default:
            break
        }
        throw AppError.inferenceFailed(underlying: "张量布局无法解析：\(shape)")
    }
}
