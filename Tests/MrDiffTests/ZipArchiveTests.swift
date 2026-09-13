import XCTest
@testable import MrDiffCore

/// zip の一覧・指紋・展開と、docx の段落抜き。フィクスチャは Python の zipfile で作った
/// 小さな docx（本文 3〜4 段落 ＋ タブ 1 つ）と、素の zip 2 つ。
final class ZipArchiveTests: XCTestCase {

    private func load(_ name: String) throws -> Data {
        let u = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: u)
    }

    func test_zipを見分ける() throws {
        XCTAssertTrue(ZipArchive.looksLikeZip(try load("plain-a.zip")))
        XCTAssertTrue(ZipArchive.looksLikeZip(try load("doc-a.docx")), "docx も zip")
        XCTAssertFalse(ZipArchive.looksLikeZip(try load("same-a.png")))
        XCTAssertNil(ZipArchive(data: Data("PK\u{3}\u{4}garbage".utf8)), "頭だけでは足りない")
    }

    func test_一覧はファイルだけ_ディレクトリの項目は落とす() throws {
        let z = try XCTUnwrap(ZipArchive(data: try load("plain-a.zip")))
        XCTAssertEqual(z.entries.map(\.path).sorted(), ["img/x.bin", "readme.txt"])
    }

    func test_指紋はCRCと長さ_同じ中身なら同じ() throws {
        let a = try XCTUnwrap(ZipArchive(data: try load("plain-a.zip")))
        let b = try XCTUnwrap(ZipArchive(data: try load("plain-b.zip")))
        XCTAssertNotEqual(a.fingerprints["readme.txt"], b.fingerprints["readme.txt"])
        // 中身が同じでパスが違う 2 つ（x.bin / y.bin）は同じ指紋
        XCTAssertEqual(a.fingerprints["img/x.bin"], b.fingerprints["img/y.bin"])
    }

    func test_中身をフォルダとして突き合わせる() throws {
        let a = try XCTUnwrap(ZipArchive(data: try load("plain-a.zip"))).fingerprints
        let b = try XCTUnwrap(ZipArchive(data: try load("plain-b.zip"))).fingerprints
        let d = TreeDiff.compare(leftPaths: a.keys.sorted(), rightPaths: b.keys.sorted(),
                                 leftHash: { a[$0] }, rightHash: { b[$0] })
        XCTAssertEqual(d.changed.map(\.path), ["readme.txt"])
        XCTAssertEqual(d.onlyLeft.map(\.path), ["img/x.bin"])
        XCTAssertEqual(d.onlyRight.map(\.path), ["img/y.bin"])
    }

    func test_展開_DEFLATEと無圧縮() throws {
        let z = try XCTUnwrap(ZipArchive(data: try load("plain-a.zip")))
        XCTAssertEqual(z.extract("readme.txt"), Data("hello\n".utf8))
        XCTAssertEqual(z.extract("img/x.bin"), Data(0...255))
        XCTAssertNil(z.extract("nope"))
        let s = try XCTUnwrap(ZipArchive(data: try load("doc-stored.docx")))
        XCTAssertNotNil(s.extract("word/document.xml"), "method 0（無圧縮）も起こせる")
    }

    // MARK: - docx

    func test_docxの段落を抜く_タブはタブ() throws {
        let z = try XCTUnwrap(ZipArchive(data: try load("doc-a.docx")))
        let p = try XCTUnwrap(DocxText.paragraphs(in: z))
        XCTAssertEqual(p.count, 4)
        XCTAssertEqual(p[0], "第1条 甲は乙に対し、納期を 2026年10月31日 とする。")
        XCTAssertEqual(p[3], "tab\tafter")
    }

    func test_docxは段落の行diffになる() throws {
        let a = try XCTUnwrap(ZipArchive(data: try load("doc-a.docx")))
        let b = try XCTUnwrap(ZipArchive(data: try load("doc-b.docx")))
        let d = compareText(try XCTUnwrap(DocxText.text(in: a)), try XCTUnwrap(DocxText.text(in: b)))
        XCTAssertFalse(d.isIdentical)
        XCTAssertEqual(d.changed, 1, "納期の段落")
        XCTAssertEqual(d.added, 1, "第4条")
        XCTAssertEqual(d.removed, 0)
    }

    func test_docxでないzipには本文が無い() throws {
        let z = try XCTUnwrap(ZipArchive(data: try load("plain-a.zip")))
        XCTAssertNil(DocxText.paragraphs(in: z))
    }
}
