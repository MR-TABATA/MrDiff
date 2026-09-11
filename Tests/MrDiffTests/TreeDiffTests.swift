import XCTest
@testable import MrDiffCore

/// 両方向の突き合わせの試験。
///
/// **本丸は onlyRight（置き忘れ）。** これが SiteDiff（片方向）で出せなかったもので、
/// TreeDiff を足した理由そのもの。
final class TreeDiffTests: XCTestCase {

    private func diff(_ left: [String: String], _ right: [String: String]) -> TreeDiff {
        TreeDiff.compare(leftPaths: left.keys.sorted(), rightPaths: right.keys.sorted(),
                         leftHash: { left[$0] }, rightHash: { right[$0] })
    }

    func testIdenticalAndChanged() {
        let d = diff(["a": "1", "b": "2"], ["a": "1", "b": "X"])
        XCTAssertEqual(d.identical.map(\.path), ["a"])
        XCTAssertEqual(d.changed.map(\.path), ["b"])
        XCTAssertFalse(d.allIdentical)
    }

    /// 手元にあってリモートに無い＝デプロイ漏れ。
    func testOnlyLeft() {
        let d = diff(["a": "1", "new": "2"], ["a": "1"])
        XCTAssertEqual(d.onlyLeft.map(\.path), ["new"])
    }

    /// **リモートにあって手元に無い＝置き忘れ（本丸）。**
    func testOnlyRightIsTheLeftover() {
        let d = diff(["a": "1"], ["a": "1", "customers.xlsx": "secret"])
        XCTAssertEqual(d.onlyRight.map(\.path), ["customers.xlsx"])
        XCTAssertFalse(d.allIdentical)
    }

    /// 3 種類が同時に出る。
    func testAllThreeKinds() {
        let d = diff(["same": "=", "local": "L", "both": "1"],
                     ["same": "=", "both": "2", "stale": "old"])
        XCTAssertEqual(Set(d.identical.map(\.path)), ["same"])
        XCTAssertEqual(Set(d.changed.map(\.path)), ["both"])
        XCTAssertEqual(Set(d.onlyLeft.map(\.path)), ["local"])
        XCTAssertEqual(Set(d.onlyRight.map(\.path)), ["stale"])
    }

    func testAllIdentical() {
        let d = diff(["a": "1", "b": "2"], ["a": "1", "b": "2"])
        XCTAssertTrue(d.allIdentical)
    }

    func testEmptyBothSides() {
        XCTAssertTrue(diff([:], [:]).allIdentical)
    }

    /// 右だけの集合が全部置き忘れになる（左が空）。
    func testEmptyLeft() {
        let d = diff([:], ["a": "1", "b": "2"])
        XCTAssertEqual(Set(d.onlyRight.map(\.path)), ["a", "b"])
        XCTAssertTrue(d.onlyLeft.isEmpty)
    }

    /// 同じパスを 2 回渡しても 1 行（左の重複）。
    func testDuplicateLeftPathCountedOnce() {
        let d = TreeDiff.compare(leftPaths: ["a", "a"], rightPaths: ["a"],
                                 leftHash: { _ in "1" }, rightHash: { _ in "1" })
        XCTAssertEqual(d.rows.count, 1)
    }
}

/// RemoteTree.local の試験（実ファイルを歩く。SSH は鍵が要るので単体では叩かない）。
final class RemoteTreeLocalTests: XCTestCase {

    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"),
                                                withIntermediateDirectories: true)
        try "hello\n".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "css\n".write(to: root.appendingPathComponent("a/style.css"), atomically: true, encoding: .utf8)
        return root
    }

    func testWalksRecursivelyWithRelativePaths() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let map = try RemoteTree.local(root)
        XCTAssertEqual(Set(map.keys), ["index.html", "a/style.css"])
    }

    /// **リモートで find+md5sum が出す値と、ここで出す MD5 が一致すること。**
    /// これが一致しないと、SSH diff が「全部 changed」になる。
    /// `hello\n` の MD5 は既知（b1946ac92492d2347c6235b4d2611184）。
    func testMD5MatchesTheKnownValue() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let map = try RemoteTree.local(root)
        XCTAssertEqual(map["index.html"], "b1946ac92492d2347c6235b4d2611184")
    }

    func testMD5FunctionDirectly() {
        XCTAssertEqual(RemoteTree.md5(Data("hello\n".utf8)), "b1946ac92492d2347c6235b4d2611184")
    }

    /// パスにシングルクォートが入っても、リモートへ 1 引数で渡せる形に固める。
    func testShellQuote() {
        XCTAssertEqual(RemoteTree.shellQuote("/var/www"), "'/var/www'")
        XCTAssertEqual(RemoteTree.shellQuote("/a/o'brien"), "'/a/o'\\''brien'")
    }

    func testNonDirectoryThrows() {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        try? "x".write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertThrowsError(try RemoteTree.local(f))
    }
}
