import XCTest
@testable import MrDiffCore

/// JSON / YAML の構造比較。**キーの並び替えは差分に出ない**ことと、配列は位置で見る
/// （途中への挿入を「全部ずれた」と言わない）ことが本丸 ―― どちらも行 diff では
/// 出せなかった穴（README「the same with the keys in a different order」）。
final class StructuredDiffTests: XCTestCase {

    private func json(_ s: String) -> StructuredValue {
        guard let v = JSONStructured.parse(Data(s.utf8)) else {
            XCTFail("failed to parse JSON: \(s)")
            return .null
        }
        return v
    }

    private func diff(_ a: String, _ b: String) -> StructuredDiff {
        compareStructured(json(a), json(b))
    }

    // MARK: - オブジェクト

    func testIdenticalObjectsHaveNoChanges() {
        let d = diff(#"{"a":1,"b":"x"}"#, #"{"a":1,"b":"x"}"#)
        XCTAssertTrue(d.isIdentical)
    }

    /// **本丸。** キーの並びだけ違っても「同じ」。
    func testKeyOrderDoesNotCountAsAChange() {
        let d = diff(#"{"a":1,"b":2,"c":3}"#, #"{"c":3,"a":1,"b":2}"#)
        XCTAssertTrue(d.isIdentical)
    }

    func testAddedKey() {
        let d = diff(#"{"a":1}"#, #"{"a":1,"b":2}"#)
        XCTAssertEqual(d.added, 1)
        XCTAssertEqual(d.changed, 0)
        XCTAssertEqual(d.removed, 0)
        XCTAssertEqual(d.changes, [StructuredChange(path: "b", kind: .added)])
    }

    func testRemovedKey() {
        let d = diff(#"{"a":1,"b":2}"#, #"{"a":1}"#)
        XCTAssertEqual(d.removed, 1)
        XCTAssertEqual(d.changes, [StructuredChange(path: "b", kind: .removed)])
    }

    func testChangedValue() {
        let d = diff(#"{"a":1}"#, #"{"a":2}"#)
        XCTAssertEqual(d.changed, 1)
        XCTAssertEqual(d.changes, [StructuredChange(path: "a", kind: .changed)])
    }

    func testNestedPathUsesDots() {
        let d = diff(#"{"user":{"name":"a"}}"#, #"{"user":{"name":"b"}}"#)
        XCTAssertEqual(d.changes, [StructuredChange(path: "user.name", kind: .changed)])
    }

    // MARK: - 配列

    func testIdenticalArrays() {
        XCTAssertTrue(diff("[1,2,3]", "[1,2,3]").isIdentical)
    }

    func testAppendedElement() {
        let d = diff("[1,2,3]", "[1,2,3,4]")
        XCTAssertEqual(d.changes, [StructuredChange(path: "[3]", kind: .added)])
    }

    /// **途中への挿入は、後ろ全部を「変更」にしない。**LineDiff を再利用している効き目。
    func testInsertionInTheMiddleDoesNotShiftEverythingElse() {
        let d = diff("[1,2,3]", "[1,99,2,3]")
        XCTAssertEqual(d.changes, [StructuredChange(path: "[1]", kind: .added)])
    }

    func testRemovedElement() {
        let d = diff("[1,2,3]", "[1,3]")
        XCTAssertEqual(d.changes, [StructuredChange(path: "[1]", kind: .removed)])
    }

    func testArrayOfObjectsDiffsByIndex() {
        let d = diff(#"[{"id":1,"n":"a"},{"id":2,"n":"b"}]"#,
                     #"[{"id":1,"n":"a"},{"id":2,"n":"c"}]"#)
        XCTAssertEqual(d.changes, [StructuredChange(path: "[1].n", kind: .changed)])
    }

    // MARK: - 種類が変わる

    func testTypeChangeIsOneChangedNotACascade() {
        let d = diff(#"{"a":{"x":1,"y":2}}"#, #"{"a":[1,2]}"#)
        XCTAssertEqual(d.changes, [StructuredChange(path: "a", kind: .changed)])
    }

    func testRootTypeChangeUsesEmptyPath() {
        let d = diff("[1,2,3]", #"{"a":1}"#)
        XCTAssertEqual(d.changes, [StructuredChange(path: "", kind: .changed)])
    }

    // MARK: - 数値・真偽・null

    func testNumberFormattingDoesNotMatterOnlyValue() {
        // 1 と 1.0 は同じ値。JSONSerialization は両方 Double へ落とすので、素通りする。
        XCTAssertTrue(diff(#"{"a":1}"#, #"{"a":1.0}"#).isIdentical)
    }

    func testBoolIsNotConfusedWithNumber() {
        let d = diff(#"{"a":true}"#, #"{"a":1}"#)
        XCTAssertEqual(d.changed, 1)
    }

    func testNullVsValue() {
        let d = diff(#"{"a":null}"#, #"{"a":0}"#)
        XCTAssertEqual(d.changed, 1)
    }

    // MARK: - parseStructured の入口

    func testPlainProseIsNotMisdetectedAsStructured() {
        XCTAssertNil(parseStructured(Data("hello world, this is a sentence.".utf8)))
    }

    func testBareScalarJSONDoesNotCountAsStructured() {
        XCTAssertNil(parseStructured(Data("42".utf8)))
        XCTAssertNil(parseStructured(Data(#""just a string""#.utf8)))
    }

    func testObjectJSONIsDetectedAsJSON() {
        let r = parseStructured(Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(r?.1, "json")
    }

    func testArrayIsDetectedAsStructured() {
        let r = parseStructured(Data("[1,2,3]".utf8))
        XCTAssertEqual(r?.1, "json")
    }
}
