//
//  ImportedModelTests.swift
//  VTFrameProTests
//
//  导入模型元数据测试（ImportedModel）。
//  覆盖规则：ARCHITECTURE.md §8.1（engineID 约定 "coreml-<UUID>"）；R-13/R-19（沙盒清单、文件大小文案）。
//

import Foundation
import XCTest
@testable import VTFramePro

final class ImportedModelTests: XCTestCase {

    private func makeModel(id: UUID = UUID(),
                           kind: EngineCapability = .frameInterpolation) -> ImportedModel {
        let input = TensorSpec(name: "frame0", batch: 1, channels: 3,
                               height: 720, width: 1280,
                               pixelFormat: .rgbInterleaved, isStatic: true)
        let output = TensorSpec(name: "output", batch: 1, channels: 3,
                                height: 720, width: 1280,
                                pixelFormat: .rgbInterleaved, isStatic: true)
        return ImportedModel(
            id: id,
            displayName: "MyModel",
            declaredKind: kind,
            sandboxFileName: "\(id.uuidString).mlpackage",
            tensorContract: TensorContract(inputs: [input], outputs: [output]),
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileSizeBytes: 12_345_678
        )
    }

    /// engineID 约定：coreml-<模型UUID>（§8.1）。
    func testEngineID_convention() {
        let id = UUID()
        let model = makeModel(id: id)
        XCTAssertEqual(model.engineID, "coreml-\(id.uuidString)")
    }

    /// capabilities 语义由 declaredKind 决定（第 2.4 节：每个模型一个引擎实例）。
    func testDeclaredKind_mapsToCapability() {
        XCTAssertEqual(makeModel(kind: .frameInterpolation).declaredKind, .frameInterpolation)
        XCTAssertEqual(makeModel(kind: .superResolution).declaredKind, .superResolution)
    }

    /// 文件大小友好文案（ByteCountFormatter，R-19 模型库展示）。
    func testFileSizeDescription_nonEmpty() {
        let model = makeModel(fileSizeBytes: 12_345_678)
        XCTAssertFalse(model.fileSizeDescription.isEmpty)
    }

    /// Codable：清单 manifest.json 持久化 round-trip（R-13 沙盒清单）。
    func testCodable_roundTrip() throws {
        let model = makeModel()
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(ImportedModel.self, from: data)
        XCTAssertEqual(decoded, model)
    }

    /// 值语义 / 等值。
    func testEquality() {
        let id = UUID()
        XCTAssertEqual(makeModel(id: id), makeModel(id: id))
        XCTAssertNotEqual(makeModel(id: id), makeModel(id: UUID()))
    }
}