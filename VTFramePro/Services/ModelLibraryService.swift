//
//  ModelLibraryService.swift
//  VTFramePro
//
//  mlpackage 导入 / 拷贝沙盒 / 校验 / 清单持久化 / 删除（L3 媒体服务层）。
//  对应 PRD R-13（模型导入存沙盒，不内置）与 R-19（元信息展示、删除）。
//
//  沙盒布局：
//  ```
//  Documents/ImportedModels/
//  ├── manifest.json          # 清单（[ImportedModel] Codable）
//  └── <UUID>.mlpackage/      # 模型实体（用户经「文件」App 可管理，UIFileSharingEnabled）
//  ```
//  分层：张量校验委托 L4 的 `TensorValidator`（L3 不 import CoreML，§1.2）。
//

import Foundation
import OSLog

/// 模型库服务。
///
/// 线程：actor 隔离清单读写，避免导入/删除并发竞态。
actor ModelLibraryService {

    // MARK: - 私有

    /// 张量校验器（L4 注入，构造于 DI 容器）。
    private let tensorValidator: TensorValidator
    /// 模型根目录（Documents/ImportedModels）。
    private let modelsDirectory: URL
    /// 清单文件 URL。
    private var manifestURL: URL {
        modelsDirectory.appending(path: "manifest.json")
    }
    /// 内存清单（loadManifest 后非空）。
    private var manifest: [ImportedModel]?
    private let logger = Logger(subsystem: "com.vtframepro", category: "media")

    // MARK: - 初始化

    init(tensorValidator: TensorValidator = TensorValidator()) {
        self.tensorValidator = tensorValidator
        self.modelsDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "ImportedModels", directoryHint: .isDirectory)
    }

    // MARK: - 清单

    /// 加载清单（首次从磁盘读，之后走内存缓存）。
    func loadManifest() -> [ImportedModel] {
        if let manifest { return manifest }
        let loaded = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode([ImportedModel].self, from: $0) } ?? []
        manifest = loaded
        logger.notice("模型清单已加载: \(loaded.count) 个模型")
        return loaded
    }

    // MARK: - 导入

    /// 导入 mlpackage：安全域访问 → 拷入沙盒 → 张量校验 → 清单持久化。
    ///
    /// 任一校验规则不满足即拒绝入库并抛出全部原因（R-32）。
    ///
    /// - Parameters:
    ///   - sourceURL: 文件选择器返回的 mlpackage URL。
    ///   - declaredKind: 用户声明的用途（补帧/超分，校验基准）。
    /// - Returns: 入库的模型元数据。
    /// - Throws: `AppError.modelValidationFailed(reasons:)` / `.ioFailed`。
    func importModel(from sourceURL: URL,
                     declaredKind: EngineCapability) throws -> ImportedModel {
        // 安全域资源访问（文件选择器/「用其他应用打开」场景）。
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        // 拷入沙盒（先拷贝后校验，校验失败连沙盒副本一起清除，保证无垃圾残留）。
        let modelID = UUID()
        let sandboxFileName = "\(modelID.uuidString).mlpackage"
        let destinationURL = modelsDirectory.appending(path: sandboxFileName, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw AppError.ioFailed(underlying: "模型拷贝失败：\(error.localizedDescription)")
        }

        do {
            // 编译 + 张量校验（L4 校验器：compileModel → 描述读取 → 五规则）。
            let contract = try compileAndValidate(modelURL: destinationURL, declaredKind: declaredKind)

            let fileSize = (try? FileManager.default.directorySize(at: destinationURL)) ?? 0
            let descriptor = ImportedModel(
                id: modelID,
                displayName: sourceURL.deletingPathExtension().lastPathComponent,
                declaredKind: declaredKind,
                sandboxFileName: sandboxFileName,
                tensorContract: contract,
                importedAt: Date(),
                fileSizeBytes: fileSize
            )
            var current = loadManifest()
            current.append(descriptor)
            try persist(manifest: current)
            manifest = current
            logger.notice("模型导入成功: \(descriptor.displayName) [\(declaredKind.displayName)]")
            return descriptor
        } catch {
            // 校验/持久化失败：清除沙盒副本（拒绝入库不留残留）。
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    // MARK: - 删除

    /// 删除模型：清单移除 + 沙盒实体删除（编译缓存由引擎侧惰性重建/清理）。
    ///
    /// - Parameter modelID: 模型标识。
    /// - Returns: 被删除的元数据（供 DI 反注册引擎）。
    @discardableResult
    func delete(modelID: UUID) throws -> ImportedModel {
        var current = loadManifest()
        guard let index = current.firstIndex(where: { $0.id == modelID }) else {
            throw AppError.ioFailed(underlying: "模型不存在")
        }
        let removed = current.remove(at: index)
        try persist(manifest: current)
        manifest = current
        let modelURL = modelsDirectory.appending(path: removed.sandboxFileName, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: modelURL)
        logger.notice("模型已删除: \(removed.displayName)")
        return removed
    }

    // MARK: - 路径解析

    /// 模型的沙盒实体 URL（供引擎构造）。
    nonisolated func sandboxURL(for descriptor: ImportedModel) -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "ImportedModels", directoryHint: .isDirectory)
            .appending(path: descriptor.sandboxFileName, directoryHint: .isDirectory)
    }

    // MARK: - 存储统计

    /// 模型目录总大小（设置页存储占用展示）。
    func storageBytes() -> Int64 {
        (try? FileManager.default.directorySize(at: modelsDirectory)) ?? 0
    }

    // MARK: - 私有：编译 + 校验

    /// mlpackage 编译为 mlmodelc 后执行张量五规则校验。
    private func compileAndValidate(modelURL: URL,
                                    declaredKind: EngineCapability) throws -> TensorContract {
        // 编译（CoreML 符号收敛在 L4：此处经校验器完成，L3 不直接 import CoreML）。
        let compiledURL = try TensorValidatorCompiler.compile(modelURL: modelURL)
        defer {
            // 编译产物为临时文件，校验后即清理（引擎 prepare 时按需重编译并持久缓存）。
            try? FileManager.default.removeItem(at: compiledURL)
        }
        return try tensorValidator.validate(modelURL: compiledURL, declaredKind: declaredKind)
    }

    // MARK: - 私有：持久化

    private func persist(manifest: [ImportedModel]) throws {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw AppError.ioFailed(underlying: "清单保存失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - FileManager 目录大小工具

extension FileManager {
    /// 目录递归大小（字节）。
    func directorySize(at url: URL) throws -> Int64 {
        guard let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
