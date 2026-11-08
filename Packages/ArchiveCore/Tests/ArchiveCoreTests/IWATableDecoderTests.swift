//
//  IWATableDecoderTests.swift
//  ArchiveCoreTests
//
//  Audit R6 "IWA numeric cells": the cell-record layouts byte by byte. The
//  real files (Tika's Numbers / Keynote / Pages 2013, pre-BNC v4 storage) are
//  in TikaODFIWorkFixtureTests; Numbers 5+ (v5 storage, decimal128 numbers,
//  wide offsets) has no public fixture in the corpus, so its records are
//  built here from the published layout (numbers-parser / SheetJS).
//

import XCTest
@testable import ArchiveCore

final class IWATableDecoderTests: XCTestCase {

    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    static func f64(_ d: Double) -> [UInt8] { le64(d.bitPattern) }

    /// decimal128 with a binary coefficient (hi:lo, 113 bits), exponent and sign, little-endian.
    static func d128(hi: UInt64 = 0, lo: UInt64, exponent: Int, negative: Bool = false) -> [UInt8] {
        let biased = UInt64(exponent + 0x1820)
        let top = hi | (biased << 49) | (negative ? 1 << 63 : 0)
        return le64(lo) + le64(top)
    }

    static func v5(type: UInt8, flags: UInt32, _ payload: [UInt8]) -> [UInt8] { [5, type, 0, 0, 0, 0, 0, 0] + le32(flags) + payload }

    func testV5_numberCurrencyDateBooleanDurationTextRichError() {
        let strings = [7: "Seven"], rich = [3: "Rich cell"]
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 2, flags: 0x1, Self.d128(lo: 1375, exponent: -1, negative: true)), strings: strings, rich: rich), .number("-137.5"))
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 10, flags: 0x1, Self.d128(lo: 4650, exponent: 0)), strings: strings, rich: rich), .number("4650"))
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 2, flags: 0x1, Self.d128(hi: 0x29d, lo: 0x42b6_4e76_7142_44cb, exponent: -3)), strings: strings, rich: rich),
                       .number("12345678901234567890.123"), "113-bit coefficients are printed exactly")
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 2, flags: 0x1, Self.d128(lo: 5, exponent: -4)), strings: strings, rich: rich), .number("0.0005"))
        // Date: seconds since 2001-01-01 (flag 0x4), after a double (0x2) when both are present.
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 5, flags: 0x4, Self.f64(276_048_000)), strings: strings, rich: rich), .date("2009-10-01"))
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 5, flags: 0x6, Self.f64(9) + Self.f64(276_048_000 + 3_723)), strings: strings, rich: rich), .date("2009-10-01 01:02:03"))
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 6, flags: 0x2, Self.f64(1)), strings: strings, rich: rich), .boolean(true))
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 6, flags: 0x2, Self.f64(0)), strings: strings, rich: rich), .boolean(false))
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 7, flags: 0x2, Self.f64(93_784.5)), strings: strings, rich: rich), .duration("1d 2h 3m 4.5s"))
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 3, flags: 0x8 | 0x20, Self.le32(7) + Self.le32(99)), strings: strings, rich: rich), .text("Seven"))
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 9, flags: 0x10, Self.le32(3)), strings: strings, rich: rich), .text("Rich cell"))
        XCTAssertEqual(IWATableDecoder.cell(Self.v5(type: 8, flags: 0, []), strings: strings, rich: rich), .error)
        XCTAssertNil(IWATableDecoder.cell([6, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], strings: strings, rich: rich), "an unknown storage version is not guessed")
    }

    func testV4_recordsAsWrittenByNumbers2013() {
        // Headers and flags as in testNumbers2013.numbers' tiles (Tile.iwa: the -872.4 number; Tile-2.iwa: a date, value changed).
        let number: [UInt8] = [0x04, 0x02, 0, 0, 0x2C, 0, 0, 0, 0x12, 0x08, 0x08, 0, 0x02, 0, 0, 0, 0x04, 0, 0, 0] + Self.f64(-872.4) + [2, 0, 0, 0]
        XCTAssertEqual(IWATableDecoder.cell(number, strings: [:], rich: [:]), .number("-872.4"))
        let date: [UInt8] = [0x04, 0x05, 0, 0, 0xC4, 0, 0, 0, 0x18, 0, 0x02, 0, 0x04, 0, 0, 0, 0x03, 0, 0, 0] + Self.f64(276_048_000) + [3, 0, 0, 0]
        XCTAssertEqual(IWATableDecoder.cell(date, strings: [:], rich: [:]), .date("2009-10-01"))
        let text: [UInt8] = [0x04, 0x03, 0, 0, 0x14, 0, 0, 0, 0, 0, 0, 0, 0x01, 0, 0, 0, 0x03, 0, 0, 0]
        XCTAssertEqual(IWATableDecoder.cell(text, strings: [3: "Category"], rich: [:]), .text("Category"))
    }

    /// A TileRowInfo with v5 storage and wide offsets (×4), columns 0 and 2.
    func testRowInfo_v5WideOffsets_placeCellsInTheirColumns() {
        func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { [UInt8(n << 3 | 2)] + varint(bytes.count) + bytes }
        func varint(_ v: Int) -> [UInt8] { var v = v, out: [UInt8] = []; repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0; return out }
        let first = Self.v5(type: 2, flags: 0x1, Self.d128(lo: 42, exponent: 0))      // 28 bytes
        let second = Self.v5(type: 6, flags: 0x2, Self.f64(1))                       // 20 bytes
        let storage = first + second
        var offsets: [UInt8] = []
        for column in 0..<255 {
            let value: UInt16 = column == 0 ? 0 : (column == 2 ? UInt16(first.count / 4) : 0xFFFF)
            offsets += [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        let rowInfo = Data([0x08, 0x00, 0x10, 0x02] + field(6, storage) + field(7, offsets) + [0x40, 0x01])
        let cells = IWATableDecoder.cells(rowInfo: rowInfo, strings: [:], rich: [:])
        XCTAssertEqual(cells.map(\.0), [0, 2])
        XCTAssertEqual(cells.map(\.1), [.number("42"), .boolean(true)])
    }

    /// A file saved by a current Numbers (the app's TYPE fixture): v5 cell storage, read through the tiles.
    func testREAL_currentNumbersFile_v5Storage_textCellsPlaced() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../maxmailinTests/Fixtures/iwork/sample.numbers").standardized
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("app fixture not in this checkout") }
        let scratch = try DocumentTextExtractor.scratchDirectory("v5")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var versions: Set<UInt8> = []
        for member in try ZIPArchiveReader.members(of: url) where member.name.contains("Tables/Tile") {
            for (_, object) in try IWAFile.identifiedObjects(in: try DocumentTextExtractor.memberData(member, from: url, scratch: scratch), limit: 1 << 26)
            where object.type == IWATableDecoder.tileType {
                for row in ProtobufWalker.messages(field: 5, in: object.payload) {
                    if let first = ProtobufWalker.messages(field: 6, in: row).first?.first { versions.insert(first) }
                }
            }
        }
        XCTAssertEqual(versions, [5], "the file carries Numbers 5+ cell storage")
        let r = try DocumentTextExtractor.extract(fileURL: url, kind: .numbers)
        XCTAssertTrue(r.components.contains("Table cells: Table 1 (sheet: Sheet 1)"), r.components.description)
        XCTAssertTrue(r.text.contains("Gross margin\n\tQuarterly budget review"), "cells in their rows and columns: \(r.text)")
    }

    func testNumberAndDurationFormatting() {
        XCTAssertEqual(IWATableDecoder.number(4650), "4650")
        XCTAssertEqual(IWATableDecoder.number(-97.4), "-97.4")
        XCTAssertEqual(IWATableDecoder.duration(0), "0s")
        XCTAssertEqual(IWATableDecoder.duration(-90), "-1m 30s")
        XCTAssertEqual(IWATableDecoder.duration(604_800 + 3_600), "1w 1h")
    }
}
