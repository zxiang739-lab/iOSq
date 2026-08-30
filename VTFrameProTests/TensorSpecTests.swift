//
//  TensorSpecTests.swift
//  VTFrameProTests
//
//  张量规格值类型测试（TensorPixelFormat / TensorSpec / TensorContract）。
//  覆盖规则：PRD §3.4-5 规则②（通道数与像素格式一致）；ARCHITECTURE.md §4.2 Models/TensorSpec.swift。
//

import Foundation
import XCTest
@testable import VTFramePro

final class TensorSpecTests: XCTestCase {

    // MARK: - TensorPixelFormat 通道数（规则②：3 通道 RGB / 4 通道 BGRA）

    func testPixelFormat_channelCount() {
        XCTAssertEqual(TensorPixelFormat.rgbInterleaved.channelCount, 3)
        XCTAssertEqual(TensorPixelFormat.bgra.channelCount, 4)
    }

    func testPixelFormat_displayName() {
        XCTAssertEqual(TensorPixelFormat.rgbInterleaved.displayName, "RGB 三通道")
        XCTAssertEqual(TensorPixelFormat.bgra.displayName, "BGRA 四通道")
    }

    // MARK: - TensorSpec 摘要与值语义

    /// summary 一行式摘要格式：name · B×C×H×W · 格式名。
    func testTensorSpec_summary_format() {
        let spec = TensorSpec(name: "frame0",
                              batch: 1, channels: 3,
                              height: 720, width: 1280,
                              pixelFormat: .rgbInterleaved,
                              isStatic: true)
        XCTAssertEqual(spec.summary, "frame0 · 1×3×720×1280 · RGB 三通道")
    }

    func testTensorSpec_equatable() {
        let a = TensorSpec(name: "f", batch: 1, channels: 4, height: 2, width: 2,
                           pixelFormat: .bgra, isStatic: true)
        let b = TensorSpec(name: "f", batch: 1, channels: 4, height: 2, width: 2,
                           pixelFormat: .bgra, isStatic: true)
        XCTAssertEqual(a, b)
    }

    /// Codable：沙盒清单持久化（ImportedModel → TensorContract → TensorSpec）round-trip。
    func testTensorSpec_codableRoundTrip() throws {
        let spec = TensorSpec(name: "input", batch: 1, channels: 3,
                              height: 1080, width: 1920,
                              pixelFormat: .rgbInterleaved, isStatic: true)
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(TensorSpec.self, from: data)
        XCTAssertEqual(decoded, spec)
    }

    // MARK: - TensorContract 摘要

    /// TensorContract.summary 汇总全部输入/输出（模型库列表展示，R-19）。
    func testTensorContract_summary_aggregates() {
        let input = TensorSpec(name: "frame0", batch: 1, channels: 3,
                               height: 720, width: 1280, pixelFormat: .rgbInterleaved, isStatic: true)
        let output = TensorSpec(name: "output", batch: 1, channels: 3,
                                height: 1440, width: 2560, pixelFormat: .rgbInterleaved, isStatic: true)
        let contract = TensorContract(inputs: [input], outputs: [output])
        let summary = contract.summary
        XCTAssertTrue(summary.contains("输入"), "应含「输入」段")
        XCTAssertTrue(summary.contains("输出"), "应含「输出」段")
        XCTAssertTrue(summary.contains("frame0"))
        XCTAssertTrue(summary.contains("output"))
        XCTAssertTrue(summary.contains("2560"), "应含输出宽度")
    }

    /// 补帧契约典型形态：2 入 1 出（PRD §3.4-5 规则①语义的数据建模）。
    func testTensorContract_interpolation_shape() {
        let make = { (name: String, w: Int) in
            TensorSpec(name: name, batch: 1, channels: 3,
                       height: 720, width: w, pixelFormat: .rgbInterleaved, isStatic: true)
        }
        let contract = TensorContract(inputs: [make("frame0", 1280), make("frame1", 1280)],
                                      outputs: [make("output", 1280)])
        XCTAssertEqual(contract.inputs.count, 2)
        XCTAssertEqual(contract.outputs.count, 1)
    }

    /// 超分契约典型形态：1 入 1 出、输出为输入整数倍（规则③数据语义）。
    func testTensorContract_superResolution_scaleSemantics() {
        let input = TensorSpec(name: "input", batch: 1, channels: 4,
                               height: 720, width: 1280, pixelFormat: .bgra, isStatic: true)
        let output = TensorSpec(name: "output", batch: 1, channels: 4,
                                height: 1440, width: 2560, pixelFormat: .bgra, isStatic: true)
        let contract = TensorContract(inputs: [input], outputs: [output])
        XCTAssertEqual(contract.outputs[0].width % contract.inputs[0].width, 0)
        XCTAssertEqual(contract.outputs[0].height / contract.inputs[0].height, 2)
    }
}