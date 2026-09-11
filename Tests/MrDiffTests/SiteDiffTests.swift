import XCTest
@testable import MrDiffCore

/// サイト突き合わせの試験。**本物のネットワークは叩かない** ―― fetch を差し替える。
///
/// 見るのは分類（同じ・違う・デプロイ漏れ・取れなかった）と、
/// **「取れなかった」を「同期している」に混ぜないこと**。
final class SiteDiffTests: XCTestCase {

    private func e(_ path: String) -> SiteMap.Entry {
        .init(localPath: path, url: URL(string: "https://x/\(path)")!)
    }

    private func run(_ entries: [SiteMap.Entry],
                     remote: [String: SiteDiff.Remote],
                     localData: [String: Data]) -> SiteDiff {
        SiteDiff.compare(entries: entries,
                         fetch: { url in remote[url.lastPathComponent] ?? .absent },
                         local: { localData[$0] })
    }

    func testIdenticalAndChanged() {
        let d = run([e("a.txt"), e("b.txt")],
                    remote: ["a.txt": .got(Data("same".utf8)),
                             "b.txt": .got(Data("server".utf8))],
                    localData: ["a.txt": Data("same".utf8),
                                "b.txt": Data("local".utf8)])
        XCTAssertEqual(d.identical.map(\.entry.localPath), ["a.txt"])
        XCTAssertEqual(d.changed.map(\.entry.localPath), ["b.txt"])
        XCTAssertFalse(d.allInSync)
    }

    /// git にあってサイトに 404 ＝ デプロイ漏れ。
    func testMissingIsADeployGap() {
        let d = run([e("new.html")],
                    remote: ["new.html": .absent],
                    localData: ["new.html": Data("hi".utf8)])
        XCTAssertEqual(d.missing.map(\.entry.localPath), ["new.html"])
        XCTAssertFalse(d.allInSync)
    }

    func testAllInSync() {
        let d = run([e("a"), e("b")],
                    remote: ["a": .got(Data("1".utf8)), "b": .got(Data("2".utf8))],
                    localData: ["a": Data("1".utf8), "b": Data("2".utf8)])
        XCTAssertTrue(d.allInSync)
        XCTAssertEqual(d.identical.count, 2)
    }

    /// **「取れなかった」を「同じ」に混ぜない。** 500 が返ったファイルがあれば、
    /// 残りが全部一致でも「同期している」とは言わない。
    func testErrorIsNotInSync() {
        let d = run([e("a"), e("b")],
                    remote: ["a": .got(Data("1".utf8)), "b": .failed("HTTP 500")],
                    localData: ["a": Data("1".utf8), "b": Data("x".utf8)])
        XCTAssertEqual(d.errored.count, 1)
        XCTAssertFalse(d.allInSync, "500 を無視して同期と言ってはいけない")
    }

    /// git に載っているのに手元で読めないファイルは、changed でも missing でもなく error。
    func testUnreadableLocalIsError() {
        let d = run([e("gone")],
                    remote: ["gone": .got(Data("x".utf8))],
                    localData: [:])
        XCTAssertEqual(d.errored.count, 1)
        XCTAssertTrue(d.changed.isEmpty)
    }

    func testEmpty() {
        let d = run([], remote: [:], localData: [:])
        XCTAssertTrue(d.allInSync)
        XCTAssertTrue(d.rows.isEmpty)
    }
}
