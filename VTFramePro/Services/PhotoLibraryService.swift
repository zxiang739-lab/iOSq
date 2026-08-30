//
//  PhotoLibraryService.swift
//  VTFramePro
//
//  PHPhotoLibrary 保存与权限（L3 媒体服务层）。
//  对应 PRD R-16（完成保存相册）与 R-11（权限）。
//

import Foundation
import Photos
import OSLog

/// 照片库保存服务。
///
/// - 权限口径：`NSPhotoLibraryAddUsageDescription`（.addOnly，最小权限原则）；
/// - 线程：无内部状态，Sendable；PHPhotoLibrary 回调桥接为 async（§8.3）。
struct PhotoLibraryService: Sendable {

    private let permissionService: PermissionService
    private let logger = Logger(subsystem: "com.vtframepro", category: "media")

    init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    // MARK: - 保存

    /// 保存视频文件到系统相册。
    ///
    /// - Parameter url: 待保存视频文件 URL。
    /// - Throws: `AppError.permissionDenied(.photoAddOnly)`（未授权）；
    ///   `AppError.ioFailed`（保存失败）。
    func saveVideo(at url: URL) async throws {
        // 权限检查（未决定现场申请，R-11）。
        let status = await permissionService.request(.photoAddOnly)
        guard status.isGranted else {
            throw AppError.permissionDenied(.photoAddOnly)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: AppError.ioFailed(
                        underlying: "相册保存失败：\(error.localizedDescription)"))
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: AppError.ioFailed(underlying: "相册保存被拒绝"))
                }
            }
        }
        logger.notice("视频已保存至相册: \(url.lastPathComponent)")
    }
}
