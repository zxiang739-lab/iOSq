//
//  AppError.swift
//  VTFramePro
//
//  统一错误域（L5 Model 层）。
//  对应 ARCHITECTURE.md §8.2：NSError domain + 错误码 + 中文友好文案。
//

import Foundation

// MARK: - 权限种类

/// 权限种类（用于权限错误归因与引导文案）。
enum PermissionKind: String, Sendable, Codable {
    /// 摄像头。
    case camera
    /// 照片库（读取）。
    case photoLibrary
    /// 照片库（仅保存）。
    case photoAddOnly

    var displayName: String {
        switch self {
        case .camera: return "摄像头"
        case .photoLibrary: return "照片库"
        case .photoAddOnly: return "照片库保存"
        }
    }
}

// MARK: - 统一错误类型

/// VTFramePro 统一错误类型。
///
/// - NSError domain：`com.vtframepro.error`；code 与各 case 注释编号一致。
/// - 抛出边界：L4/L3 只抛 `AppError`；ViewModel 捕获后映射为 UI 状态（§8.2）。
/// - `.cancelled` 与下载三态属正常状态机，不走弹窗。
enum AppError: LocalizedError, Sendable, Equatable {

    // ---- 权限 1xxx ----
    /// 1001 权限被拒绝（附权限种类）。
    case permissionDenied(PermissionKind)

    // ---- 引擎/模型 2xxx（§2.2）----
    /// 2001 引擎不支持（isSupported=false 等）。
    case engineUnsupported(detail: String)
    /// 2002 VT 系统模型下载失败。
    case modelDownloadFailed(underlying: String)
    /// 2003 张量校验失败（列全部原因）。
    case modelValidationFailed(reasons: [String])
    /// 2004 无任何可用引擎。
    case noUsableEngine(capability: EngineCapability)
    /// 2005 推理执行失败。
    case inferenceFailed(underlying: String)

    // ---- IO / 内存 4xxx ----
    /// 4001 文件/编解码/相册等 IO 失败。
    case ioFailed(underlying: String)
    /// 4002 内存压力中止（OOM 防线，§9.3）。
    case outOfMemory
    /// 4003 用户取消（非异常，不弹窗）。
    case cancelled

    // MARK: NSError 桥接

    /// NSError domain。
    static let errorDomain = "com.vtframepro.error"

    /// 错误码（与注释编号一致）。
    var errorCode: Int {
        switch self {
        case .permissionDenied: return 1001
        case .engineUnsupported: return 2001
        case .modelDownloadFailed: return 2002
        case .modelValidationFailed: return 2003
        case .noUsableEngine: return 2004
        case .inferenceFailed: return 2005
        case .ioFailed: return 4001
        case .outOfMemory: return 4002
        case .cancelled: return 4003
        }
    }

    // MARK: LocalizedError

    /// 简体中文友好文案（§8.1 文案集中约定）。
    var errorDescription: String? {
        switch self {
        case .permissionDenied(let kind):
            return "\(kind.displayName)权限未开启"
        case .engineUnsupported(let detail):
            return "当前设备不支持系统引擎（\(detail)）"
        case .modelDownloadFailed(let underlying):
            return "系统模型下载失败（\(underlying)）"
        case .modelValidationFailed(let reasons):
            return "模型校验未通过：\n" + reasons.joined(separator: "\n")
        case .noUsableEngine(let capability):
            return "没有可用的\(capability.displayName)引擎"
        case .inferenceFailed(let underlying):
            return "处理执行失败（\(underlying)）"
        case .ioFailed(let underlying):
            return "文件处理失败（\(underlying)）"
        case .outOfMemory:
            return "设备内存不足，处理已中止"
        case .cancelled:
            return "已取消"
        }
    }

    /// 引导动作建议。
    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied(let kind):
            return "请前往「设置 > 隐私与安全性 > \(kind.displayName)」开启权限后重试"
        case .engineUnsupported:
            return "可在模型库中导入自定义 CoreML 模型作为替代引擎"
        case .modelDownloadFailed:
            return "请检查网络后点击「重试」"
        case .modelValidationFailed:
            return "请确认模型张量规格符合导入约定（见 README「张量规格约定」）"
        case .noUsableEngine:
            return "请先在「模型库」导入对应用途的模型，或更换支持的设备"
        case .inferenceFailed:
            return "请切换引擎或重启处理流程后重试"
        case .ioFailed:
            return "请确认文件可访问且存储空间充足后重试"
        case .outOfMemory:
            return "请关闭其他 App 释放内存，或处理更短/更小分辨率的视频"
        case .cancelled:
            return nil
        }
    }

    /// 是否需要以弹窗呈现（取消与下载三态不弹窗）。
    var shouldPresentAlert: Bool {
        self != .cancelled
    }
}
