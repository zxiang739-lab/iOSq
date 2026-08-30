//
//  ImportedModel.swift
//  VTFramePro
//
//  用户导入模型元数据（L5 Model 层）。
//  持久化为沙盒 JSON 清单，由 ModelLibraryService 管理。
//

import Foundation

/// 一个已导入并通过张量校验的 CoreML 模型元数据。
///
/// - 引擎标识约定：`engineID = "coreml-<模型UUID>"`（§8.1）。
/// - 模型实体（.mlpackage）存放于 App 沙盒 `Documents/ImportedModels/<UUID>.mlpackage`，
///   本类型只保存元数据，持久化于 `Documents/ImportedModels/manifest.json`。
struct ImportedModel: Identifiable, Sendable, Codable, Equatable {
    /// 模型唯一标识（导入时生成）。
    var id: UUID
    /// 用户可见名称（默认取文件名去扩展名，可后续重命名）。
    var displayName: String
    /// 导入时声明的用途（决定引擎 capabilities，R-32 校验基准）。
    var declaredKind: EngineCapability
    /// 沙盒内 mlpackage 相对路径（相对于 ImportedModels 目录）。
    var sandboxFileName: String
    /// 校验通过的张量契约摘要。
    var tensorContract: TensorContract
    /// 导入时间。
    var importedAt: Date
    /// 文件大小（字节，模型库展示）。
    var fileSizeBytes: Int64

    /// 对应 AIEngine 实例的稳定标识。
    var engineID: String {
        "coreml-\(id.uuidString)"
    }

    /// 文件大小友好文案。
    var fileSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}
