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
        XCTAssertEqual(d.changes, [StructuredChange(path: "b", kind: .added, after: .number(2))])
    }

    func testRemovedKey() {
        let d = diff(#"{"a":1,"b":2}"#, #"{"a":1}"#)
        XCTAssertEqual(d.removed, 1)
        XCTAssertEqual(d.changes, [StructuredChange(path: "b", kind: .removed, before: .number(2))])
    }

    func testChangedValue() {
        let d = diff(#"{"a":1}"#, #"{"a":2}"#)
        XCTAssertEqual(d.changed, 1)
        XCTAssertEqual(d.changes, [StructuredChange(path: "a", kind: .changed, before: .number(1), after: .number(2))])
    }

    func testNestedPathUsesDots() {
        let d = diff(#"{"user":{"name":"a"}}"#, #"{"user":{"name":"b"}}"#)
        XCTAssertEqual(d.changes, [StructuredChange(path: "user.name", kind: .changed, before: .string("a"), after: .string("b"))])
    }

    // MARK: - 配列

    func testIdenticalArrays() {
        XCTAssertTrue(diff("[1,2,3]", "[1,2,3]").isIdentical)
    }

    func testAppendedElement() {
        let d = diff("[1,2,3]", "[1,2,3,4]")
        XCTAssertEqual(d.changes, [StructuredChange(path: "[3]", kind: .added, after: .number(4))])
    }

    /// **途中への挿入は、後ろ全部を「変更」にしない。**LineDiff を再利用している効き目。
    func testInsertionInTheMiddleDoesNotShiftEverythingElse() {
        let d = diff("[1,2,3]", "[1,99,2,3]")
        XCTAssertEqual(d.changes, [StructuredChange(path: "[1]", kind: .added, after: .number(99))])
    }

    func testRemovedElement() {
        let d = diff("[1,2,3]", "[1,3]")
        XCTAssertEqual(d.changes, [StructuredChange(path: "[1]", kind: .removed, before: .number(2))])
    }

    func testArrayOfObjectsDiffsByIndex() {
        let d = diff(#"[{"id":1,"n":"a"},{"id":2,"n":"b"}]"#,
                     #"[{"id":1,"n":"a"},{"id":2,"n":"c"}]"#)
        XCTAssertEqual(d.changes, [StructuredChange(path: "[1].n", kind: .changed, before: .string("b"), after: .string("c"))])
    }

    // MARK: - 種類が変わる

    func testTypeChangeIsOneChangedNotACascade() {
        let d = diff(#"{"a":{"x":1,"y":2}}"#, #"{"a":[1,2]}"#)
        XCTAssertEqual(d.changes, [StructuredChange(
            path: "a", kind: .changed,
            before: .object(["x": .number(1), "y": .number(2)]), after: .array([.number(1), .number(2)]))])
    }

    func testRootTypeChangeUsesEmptyPath() {
        let d = diff("[1,2,3]", #"{"a":1}"#)
        XCTAssertEqual(d.changes, [StructuredChange(
            path: "", kind: .changed,
            before: .array([.number(1), .number(2), .number(3)]), after: .object(["a": .number(1)]))])
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

    // MARK: - shortDescription（一覧に出す「変更前 → 変更後」の値）

    func testShortDescriptionOfScalars() {
        XCTAssertEqual(shortDescription(.null), "null")
        XCTAssertEqual(shortDescription(.bool(true)), "true")
        XCTAssertEqual(shortDescription(.number(42)), "42")
        XCTAssertEqual(shortDescription(.number(1.5)), "1.5")
        XCTAssertEqual(shortDescription(.string("hi")), #""hi""#)
    }

    func testShortDescriptionOfContainersIsCompactJSON() {
        XCTAssertEqual(shortDescription(.array([.number(1), .number(2), .number(3)])), "[1,2,3]")
        XCTAssertEqual(shortDescription(.object(["b": .number(2), "a": .number(1)])), #"{"a":1,"b":2}"#)
    }

    /// 長い値は切って `…` を足す。**単語は混ぜない**（訳の外なので `[N items]` のような
    /// 英単語は使えない ── 中身を JSON のまま切るだけ）。
    func testShortDescriptionTruncatesLongValues() {
        let long = StructuredValue.string(String(repeating: "x", count: 100))
        let s = shortDescription(long, maxLength: 20)
        XCTAssertEqual(s.count, 21) // 20 文字 + "…"
        XCTAssertTrue(s.hasSuffix("…"))
    }

    // MARK: - prettyPrint（GUI の行 diff に渡す、キーの並びを揃えたテキスト）

    func testPrettyPrintSortsKeys() {
        XCTAssertEqual(prettyPrint(json(#"{"b":2,"a":1}"#)), prettyPrint(json(#"{"a":1,"b":2}"#)))
    }

    /// **本丸。**キーの並びだけ違う 2 本を `prettyPrint` に通してから行 diff に掛けると、
    /// 同じテキストになって差分が出ない ── MrkDiff がこれで「見慣れた 2 画面テキスト」を保ったまま
    /// 「キーの順は無視する」を守る。
    func testPrettyPrintedTextsAreIdenticalWhenOnlyKeyOrderDiffers() {
        let a = prettyPrint(json(#"{"name":"mrdiff","version":"1.0"}"#))
        let b = prettyPrint(json(#"{"version":"1.0","name":"mrdiff"}"#))
        XCTAssertTrue(compareText(a, b).isIdentical)
    }

    func testPrettyPrintIsReadableMultiLine() {
        let s = prettyPrint(json(#"{"a":1,"list":[1,2]}"#))
        XCTAssertEqual(s, "{\n  \"a\": 1,\n  \"list\": [\n    1,\n    2\n  ]\n}")
    }

    // MARK: - prettyPrintWithPaths（GUI が「この行は何のパスか」を引くためのもの）

    /// **一致を縛る。**ここが `prettyPrint` とずれると、行からパスへ引いた結果が信用できない。
    func testPrettyPrintWithPathsMatchesPrettyPrintText() {
        for s in [#"{"a":1,"list":[1,2],"user":{"name":"x"}}"#, "[1,2,3]", "{}", "[]",
                  #"{"items":[{"id":1},{"id":2}]}"#] {
            let v = json(s)
            XCTAssertEqual(prettyPrintWithPaths(v).text, prettyPrint(v), s)
        }
    }

    func testPrettyPrintWithPathsCountsMatchLines() {
        let v = json(#"{"a":1,"list":[1,2]}"#)
        let p = prettyPrintWithPaths(v)
        XCTAssertEqual(p.linePaths.count, p.text.components(separatedBy: "\n").count)
    }

    /// 各行のパスが、`StructuredChange.path` と同じ書式で引ける。
    func testPrettyPrintWithPathsLocatesNestedKey() {
        let v = json(#"{"a":1,"user":{"name":"x","age":2}}"#)
        let p = prettyPrintWithPaths(v)
        let lines = p.text.components(separatedBy: "\n")
        // {
        //   "a": 1,
        //   "user": {
        //     "age": 2,
        //     "name": "x"
        //   }
        // }
        XCTAssertEqual(lines[1], "  \"a\": 1,")
        XCTAssertEqual(p.linePaths[1], "a")
        XCTAssertEqual(lines[2], "  \"user\": {")
        XCTAssertEqual(p.linePaths[2], "user")
        XCTAssertEqual(lines[3], "    \"age\": 2,")
        XCTAssertEqual(p.linePaths[3], "user.age")
        XCTAssertEqual(lines[4], "    \"name\": \"x\"")
        XCTAssertEqual(p.linePaths[4], "user.name")
    }

    func testPrettyPrintWithPathsLocatesArrayElement() {
        let v = json(#"{"items":[10,20]}"#)
        let p = prettyPrintWithPaths(v)
        let lines = p.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[2], "    10,")
        XCTAssertEqual(p.linePaths[2], "items[0]")
        XCTAssertEqual(lines[3], "    20")
        XCTAssertEqual(p.linePaths[3], "items[1]")
    }
}
