import XCTest
@testable import MrDiffCore

/// 改行コードの検出と、違いの注記。**直さないこと**（CR だけの区切りは行に切らない）も固定する。
final class LineEndingTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    func testDetectsEachStyle() {
        XCTAssertEqual(LineEnding.detect(d("a\nb\n")), .lf)
        XCTAssertEqual(LineEnding.detect(d("a\r\nb\r\n")), .crlf)
        XCTAssertEqual(LineEnding.detect(d("a\rb\r")), .cr)
        XCTAssertEqual(LineEnding.detect(d("just one line")), .none)
        XCTAssertEqual(LineEnding.detect(Data()), .none)
    }

    func testMixedWhenMoreThanOneKindAppears() {
        XCTAssertEqual(LineEnding.detect(d("a\nb\r\nc\n")), .mixed)
        XCTAssertEqual(LineEnding.detect(d("a\r\nb\rc")), .mixed)
        // CR の直後が LF なら CRLF の一部で、CR 単独ではない
        XCTAssertEqual(LineEnding.detect(d("a\r\n")), .crlf)
    }

    func testDifferenceOnlyWhenBothHaveLineBreaksAndTheyDiffer() throws {
        let e = try XCTUnwrap(LineEnding.difference(d("a\nb\n"), d("a\r\nb\r\n")))
        XCTAssertEqual(e.a, .lf)
        XCTAssertEqual(e.b, .crlf)
        XCTAssertNil(LineEnding.difference(d("a\nb\n"), d("a\nc\n")), "同じ改行コードなら違いとは言わない")
        XCTAssertNil(LineEnding.difference(d("one line"), d("a\r\nb\r\n")), "片方に改行が無いなら言わない")
        XCTAssertNotNil(LineEnding.difference(d("a\nb\r\n"), d("a\nb\n")), "混在と LF は違う")
    }

    /// **CRLF と LF が同じ扱いなのは、変えていない。** 注記は添えるが、判定は「違いなし」のまま。
    func testCRLFAndLFStillCompareAsIdentical() {
        let diff = compareText(TextSource(data: d("a\nb\n")), TextSource(data: d("a\r\nb\r\n")))
        XCTAssertTrue(diff.isIdentical)
    }

    /// **CR だけの区切りは、行に切らない（直さないと決めた）。** 1 本の長い行として読む。
    func testALoneCRIsStillNotALineBreak() {
        let src = TextSource(data: d("a\rb\rc\r"))
        XCTAssertEqual(src.count, 1)
    }

    func testJSONCarriesTheDifferenceOnlyWhenThereIsOne() throws {
        let same = compareText(TextSource(data: d("a\n")), TextSource(data: d("a\n")))
        XCTAssertNil(JSONOutput.text(same)["line_endings"])
        let with = JSONOutput.text(same, lineEndings: (.lf, .crlf))
        let o = try XCTUnwrap(with["line_endings"] as? [String: String])
        XCTAssertEqual(o, ["a": "LF", "b": "CRLF"])
        XCTAssertEqual(with["result"] as? String, "identical")
    }
}
