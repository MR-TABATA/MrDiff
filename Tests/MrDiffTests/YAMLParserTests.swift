import XCTest
@testable import MrDiffCore

/// YAML パーサ。**対応していない構文は読めた気にならず、必ず投げる**ことが本丸
/// ―― 誤読して「同じ」と言い切るほうが、諦めて行 diff に戻るより害が大きい
/// （`YAMLParser.swift` 冒頭の注記）。
final class YAMLParserTests: XCTestCase {

    private func parse(_ s: String) throws -> StructuredValue {
        try YAMLParser.parse(Data(s.utf8))
    }

    // MARK: - ブロック

    func testSimpleMapping() throws {
        let v = try parse("a: 1\nb: two\n")
        XCTAssertEqual(v, .object(["a": .number(1), "b": .string("two")]))
    }

    func testNestedMapping() throws {
        let v = try parse("""
        user:
          name: alice
          age: 30
        """)
        XCTAssertEqual(v, .object(["user": .object(["name": .string("alice"), "age": .number(30)])]))
    }

    func testSimpleSequence() throws {
        let v = try parse("- a\n- b\n- c\n")
        XCTAssertEqual(v, .array([.string("a"), .string("b"), .string("c")]))
    }

    func testSequenceOfMappings() throws {
        let v = try parse("""
        - id: 1
          name: a
        - id: 2
          name: b
        """)
        XCTAssertEqual(v, .array([
            .object(["id": .number(1), "name": .string("a")]),
            .object(["id": .number(2), "name": .string("b")]),
        ]))
    }

    func testMappingWithNestedSequenceValue() throws {
        let v = try parse("""
        ports:
          - 80
          - 443
        """)
        XCTAssertEqual(v, .object(["ports": .array([.number(80), .number(443)])]))
    }

    func testNestedSequenceOfSequences() throws {
        let v = try parse("""
        - - 1
          - 2
        - - 3
        """)
        XCTAssertEqual(v, .array([.array([.number(1), .number(2)]), .array([.number(3)])]))
    }

    // MARK: - スカラ

    func testScalarTypes() throws {
        let v = try parse("""
        s: hello
        n: 42
        f: 3.5
        neg: -1
        t: true
        fa: false
        nul: null
        tilde: ~
        empty:
        """)
        XCTAssertEqual(v, .object([
            "s": .string("hello"), "n": .number(42), "f": .number(3.5), "neg": .number(-1),
            "t": .bool(true), "fa": .bool(false), "nul": .null, "tilde": .null, "empty": .null,
        ]))
    }

    func testQuotedStrings() throws {
        let v = try parse(#"""
        a: "double \"quoted\" with \n newline"
        b: 'single ''quoted'''
        c: "not-a-number: 007"
        """#)
        XCTAssertEqual(v, .object([
            "a": .string("double \"quoted\" with \n newline"),
            "b": .string("single 'quoted'"),
            "c": .string("not-a-number: 007"),
        ]))
    }

    func testCommentsAreStrippedButNotInsideQuotes() throws {
        let v = try parse("""
        # leading comment
        a: 1 # trailing comment
        b: "value # not a comment"
        """)
        XCTAssertEqual(v, .object(["a": .number(1), "b": .string("value # not a comment")]))
    }

    func testColonInPlainScalarIsNotAKeySeparator() throws {
        // `:` の後ろが空白でなければ区切りではない ―― URL を key: value と誤読しない。
        let v = try parse("url: http://example.com/x")
        XCTAssertEqual(v, .object(["url": .string("http://example.com/x")]))
    }

    // MARK: - フロー形式

    func testFlowMappingAndSequence() throws {
        let v = try parse("a: {x: 1, y: [1, 2, 3]}")
        XCTAssertEqual(v, .object(["a": .object(["x": .number(1), "y": .array([.number(1), .number(2), .number(3)])])]))
    }

    func testFlowSequenceOfMappings() throws {
        let v = try parse("items: [{id: 1}, {id: 2}]")
        XCTAssertEqual(v, .object(["items": .array([.object(["id": .number(1)]), .object(["id": .number(2)])])]))
    }

    // MARK: - ドキュメントの区切り

    func testLeadingDocumentMarkerIsSkipped() throws {
        let v = try parse("---\na: 1\n")
        XCTAssertEqual(v, .object(["a": .number(1)]))
    }

    func testEmptyDocumentIsNull() throws {
        XCTAssertEqual(try parse(""), .null)
        XCTAssertEqual(try parse("# just a comment\n"), .null)
    }

    // MARK: - 対応していない構文は必ず投げる

    func testAnchorsThrow() {
        XCTAssertThrowsError(try parse("a: &ref\n  x: 1\nb: *ref\n"))
    }

    func testTagsThrow() {
        XCTAssertThrowsError(try parse("a: !!str 1\n"))
    }

    func testBlockScalarsThrow() {
        XCTAssertThrowsError(try parse("a: |\n  line one\n  line two\n"))
    }

    func testMultipleDocumentsThrow() {
        XCTAssertThrowsError(try parse("a: 1\n---\nb: 2\n"))
    }

    func testTabIndentationThrows() {
        XCTAssertThrowsError(try parse("a:\n\tb: 1\n"))
    }

    func testMergeKeyThrows() {
        XCTAssertThrowsError(try parse("<<: {a: 1}\nb: 2\n"))
    }

    func testUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try parse(#"a: "unterminated"#))
    }
}
