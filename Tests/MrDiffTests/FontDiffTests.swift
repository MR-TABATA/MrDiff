import XCTest
@testable import MrDiffCore

/// フォントは macOS 付属のもので試す（フィクスチャを置かない。ライセンスの都合）。
/// 無い環境（CI の素の macOS にも Supplemental はある）では飛ばす。
final class FontDiffTests: XCTestCase {

    private func sys(_ name: String) throws -> Data {
        let u = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/\(name)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: u.path), "\(name) が無い")
        return try Data(contentsOf: u)
    }

    func test_フォントを見分ける() throws {
        XCTAssertTrue(looksLikeFont(try sys("Arial.ttf")))
        XCTAssertFalse(looksLikeFont(Data("hello".utf8)))
        XCTAssertFalse(looksLikeFont(Data([0x50, 0x4B, 0x03, 0x04])))
    }

    func test_同じフォントは1文字も違わない() throws {
        let a = try sys("Arial.ttf")
        let r = try compareFonts(a, a)
        XCTAssertTrue(r.isIdentical)
        XCTAssertEqual(r.compared, r.charactersA)
        XCTAssertGreaterThan(r.compared, 1000, "Arial は数千字持っている")
        XCTAssertEqual(r.onlyA, [])
        XCTAssertEqual(r.onlyB, [])
    }

    func test_太字は字形が違う_文字の集合は近い() throws {
        let r = try compareFonts(try sys("Arial.ttf"), try sys("Arial Bold.ttf"))
        XCTAssertFalse(r.isIdentical)
        XCTAssertGreaterThan(r.changed.count, r.compared / 2, "太さが違えば大半の字形が違う")
        XCTAssertTrue(r.changed.contains(0x41), "A")
        XCTAssertEqual(r.nameA, "Arial")
        XCTAssertEqual(r.nameB, "Arial Bold")
    }

    func test_持っている文字が違えば増減として言う() throws {
        let r = try compareFonts(try sys("Arial.ttf"), try sys("Georgia.ttf"))
        XCTAssertTrue(!r.onlyA.isEmpty || !r.onlyB.isEmpty, "Arial と Georgia の文字集合は同じではない")
    }

    func test_フォントでないものは投げる() {
        XCTAssertThrowsError(try compareFonts(Data("hello".utf8), Data("hello".utf8)))
    }

    func test_コードポイントの見せ方() {
        XCTAssertEqual(describeCodepoint(0x3042), "あ U+3042")
        XCTAssertEqual(describeCodepoint(0x41), "A U+0041")
        XCTAssertEqual(describeCodepoint(0x20), "U+0020", "空白は字だけ出しても見えない")
        XCTAssertEqual(describeCodepoint(0x0301), "U+0301", "結合文字も")
    }
}
