import XCTest
@testable import MrDiffCore

/// テキスト比較。**差分そのものの計算は `LineDiff`（MrEditor からの写し）が持っている**ので、
/// ここで固定するのはその前後 ―― 行分割・ハッシュ・種類の判定・数え上げ。

final class TextDiffTests: XCTestCase {

    // MARK: - 行に切る

    func test_末尾の改行は行を増やさない() {
        XCTAssertEqual(splitLines("a\nb\n"), ["a", "b"])
        XCTAssertEqual(splitLines("a\nb"), ["a", "b"])
    }

    /// **CRLF と LF だけの違いを「全行が違う」と言わない。**
    /// 改行コードそのものを見たいならバイナリ比較の仕事。
    func test_CRLFとLFは同じ行になる() {
        XCTAssertEqual(splitLines("a\r\nb\r\n"), ["a", "b"])
        XCTAssertEqual(compareText("a\r\nb\r\n", "a\nb\n").isIdentical, true)
    }

    func test_空なら0行() {
        XCTAssertEqual(splitLines(""), [])
        XCTAssertEqual(splitLines("\n"), [""], "改行だけなら空行が 1 つ")
    }

    // MARK: - ハッシュ

    func test_同じ行は同じハッシュ() {
        XCTAssertEqual(hashLine("status=200"), hashLine("status=200"))
    }

    func test_1文字違えば違うハッシュ() {
        XCTAssertNotEqual(hashLine("status=200"), hashLine("status=500"))
        XCTAssertNotEqual(hashLine("ab"), hashLine("ba"), "並び替えでも違う")
    }

    /// 128 ビットの両側が効いていること。片方だけ見ていたら気づけない。
    func test_ハッシュは2本とも埋まる() {
        let h = hashLine("x")
        XCTAssertNotEqual(h.a, 0)
        XCTAssertNotEqual(h.b, 0)
        XCTAssertNotEqual(h.a, h.b)
    }

    // MARK: - 種類の判定

    func test_テキストと判定する() {
        XCTAssertEqual(detectKind(Data("hello\n".utf8)), .text)
        XCTAssertEqual(detectKind(Data("日本語も\n".utf8)), .text)
        XCTAssertEqual(detectKind(Data()), .text, "空はテキスト扱い")
    }

    /// **NUL があればテキストにしない。**`diff` や `grep` と同じ線。
    func test_NULを含めばテキストにしない() {
        XCTAssertEqual(detectKind(Data([0x61, 0x00, 0x62])), .other)
    }

    func test_UTF8として読めなければテキストにしない() {
        XCTAssertEqual(detectKind(Data([0xff, 0xfe, 0x41])), .other)
    }

    // MARK: - 数え上げ

    func test_同じなら差分なし() {
        let d = compareText("a\nb\nc\n", "a\nb\nc\n")
        XCTAssertTrue(d.isIdentical)
        XCTAssertEqual([d.changed, d.added, d.removed], [0, 0, 0])
    }

    func test_足しただけ() {
        let d = compareText("a\nb\n", "a\nx\nb\n")
        XCTAssertFalse(d.isIdentical)
        XCTAssertEqual([d.changed, d.added, d.removed], [0, 1, 0])
    }

    func test_消しただけ() {
        let d = compareText("a\nx\nb\n", "a\nb\n")
        XCTAssertEqual([d.changed, d.added, d.removed], [0, 0, 1])
    }

    /// 消して足したものは **replace に畳まれる**（`LineDiff.coalesce`）。
    /// 「消して足した」より「書き換わった」のほうが読めるうえ、行内差分が効く。
    func test_書き換えはreplaceになる() {
        let d = compareText("a\nold\nb\n", "a\nnew\nb\n")
        XCTAssertEqual([d.changed, d.added, d.removed], [1, 0, 0])
        XCTAssertTrue(d.ops.contains { if case .replace = $0 { return true } else { return false } })
    }

    /// README の 1 行（`5 changed, 1 added, 0 removed`）が出る形。
    func test_混ざった場合() {
        let left = (1...10).map { "line \($0)" }.joined(separator: "\n")
        var lines = (1...10).map { "line \($0)" }
        lines[2] = "line 3 CHANGED"
        lines.insert("line inserted", at: 6)
        lines.remove(at: 9)
        let d = compareText(left, lines.joined(separator: "\n"))
        XCTAssertEqual(d.changed, 1)
        XCTAssertEqual(d.added, 1)
        XCTAssertEqual(d.removed, 1)
    }

    // MARK: - 行内差分（CharDiff・写し）

    /// **本命はここ。**ログの 1 文字違いを見つけられること。
    func test_行内の変わった範囲だけを返す() {
        let a = "GET /users status=200 latency=18ms"
        let b = "GET /users status=500 latency=18ms"
        let (l, r) = CharDiff.ranges(left: a, right: b)
        XCTAssertEqual(l.count, 1)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(String(Array(a)[l[0]]), "2")
        XCTAssertEqual(String(Array(b)[r[0]]), "5")
    }

    func test_同じ行なら行内差分は空() {
        let (l, r) = CharDiff.ranges(left: "same", right: "same")
        XCTAssertTrue(l.isEmpty)
        XCTAssertTrue(r.isEmpty)
    }

    /// 長すぎる行は行内差分を諦める（1 行 10 万文字の DP を回すほうが害）。
    func test_長すぎる行は丸ごと変更扱い() {
        let n = CharDiff.maxLineLength + 1
        let a = String(repeating: "a", count: n)
        let b = String(repeating: "b", count: n)
        let (l, r) = CharDiff.ranges(left: a, right: b)
        XCTAssertEqual(l, [0..<n])
        XCTAssertEqual(r, [0..<n])
    }

    // MARK: - 大きめ

    /// **差分が少ない大きなファイル。**共通の先頭・末尾を落とす道が効いていること
    /// （落ちていなければ、ここで時間がかかって気づく）。
    func test_1万行のうち1行だけ違う() {
        var lines = (1...10_000).map { "line \($0)" }
        let left = lines.joined(separator: "\n")
        lines[5_000] = "line 5001 CHANGED"
        let d = compareText(left, lines.joined(separator: "\n"))
        XCTAssertEqual(d.changed, 1)
        XCTAssertEqual(d.added, 0)
        XCTAssertEqual(d.removed, 0)
    }
}
