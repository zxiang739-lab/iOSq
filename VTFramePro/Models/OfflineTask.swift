//
//  OfflineTask.swift
//  VTFramePro
//
//  离线任务模型 + 状态机（L5 Model 层）。
//  对应 ARCHITECTURE.md §3.2 离线链路。
//

import Foundation

// MARK: - 任务状态机

/// 离线任务状态。
///
/// 流转：`queued` → `running(progress)` → `completed` / `failed` / `cancelled`。
/// `cancelled` 属正常用户行为（不弹错误窗，§8.2）。
enum OfflineTaskStatus: Equatable, Sendable {
    /// 排队中（严格串行，等待前一任务完成）。
    case queued
    /// 执行中，progress ∈ [0, 1]。
    case running(progress: Double)
    /// 用户取消（终态）。
    case cancelled
    /// 失败（终态），附 AppError 友好文案。
    case failed(message: String)
    /// 完成（终态），已保存照片库，附输出文件 URL（终态前临时路径）。
    case completed(outputURL: URL)

    /// 是否终态（终态后不再变更）。
    var isTerminal: Bool {
        switch self {
        case .cancelled, .failed, .completed: return true
        case .queued, .running: return false
        }
    }

    /// 面向用户的状态文案。
    var displayName: String {
        switch self {
        case .queued: return "排队中"
        case .running(let progress): return String(format: "处理中 %.0f%%", progress * 100)
        case .cancelled: return "已取消"
        case .failed(let message): return "失败：\(message)"
        case .completed: return "已完成"
        }
    }
}

// MARK: - 离线任务

/// 离线处理任务（值类型，跨 actor 传递）。
struct OfflineTask: Identifiable, Equatable, Sendable {
    /// 任务标识。
    var id: UUID
    /// 业务模式（仅离线两种：.offlineInterpolation / .offlineSuperResolution）。
    var mode: ProcessingMode
    /// 源视频文件 URL（导入时已拷入沙盒临时区）。
    var sourceVideoURL: URL
    /// 创建任务时选定的引擎标识（"system-vt" 或 "coreml-<UUID>"）。
    var engineID: String
    /// 当前状态。
    var status: OfflineTaskStatus
    /// 创建时间。
    var createdAt: Date

    /// 源文件名（列表展示）。
    var sourceFileName: String {
        sourceVideoURL.lastPathComponent
    }

    /// 构造排队态任务。
    init(id: UUID = UUID(),
         mode: ProcessingMode,
         sourceVideoURL: URL,
         engineID: String,
         createdAt: Date = Date()) {
        self.id = id
        self.mode = mode
        self.sourceVideoURL = sourceVideoURL
        self.engineID = engineID
        self.status = .queued
        self.createdAt = createdAt
    }
}
