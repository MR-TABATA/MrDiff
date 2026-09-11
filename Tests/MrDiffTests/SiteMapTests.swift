import XCTest
@testable import MrDiffCore

/// ローカル → URL の対応づけの試験。純関数なのでネットワークは要らない。
///
/// **本丸は index.html の畳み方**（配信ごとに揺れるところ）と、
/// base の末尾スラッシュの吸収。
final class SiteMapTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    private func map(_ base: String, _ paths: [String]) -> [SiteMap.Entry] {
        SiteMap.entries(base: url(base), relativePaths: paths)
    }

    func testPlainPath() {
        let e = map("https://example.com", ["css/site.css"])
        XCTAssertEqual(e, [.init(localPath: "css/site.css",
                                 url: url("https://example.com/css/site.css"))])
    }

    // MARK: - index.html を畳む

    func testRootIndexBecomesRoot() {
        XCTAssertEqual(SiteMap.urlPath(for: "index.html"), "")
    }

    func testNestedIndexBecomesDirectory() {
        XCTAssertEqual(SiteMap.urlPath(for: "docs/index.html"), "docs/")
    }

    func testRootIndexMapsToBaseItself() {
        let e = map("https://example.com", ["index.html"])
        XCTAssertEqual(e.first?.url, url("https://example.com/"))
    }

    /// **`reindex.html` を畳まない**（`index.html` で終わるが別語）。
    func testNotIndexHtml() {
        XCTAssertEqual(SiteMap.urlPath(for: "reindex.html"), "reindex.html")
        XCTAssertEqual(SiteMap.urlPath(for: "a/my-index.html"), "a/my-index.html")
    }

    // MARK: - base の揺れを吸収

    func testTrailingSlashOnBase() {
        let a = map("https://example.com/", ["a.txt"]).first?.url
        let b = map("https://example.com", ["a.txt"]).first?.url
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, url("https://example.com/a.txt"))
    }

    func testBaseWithSubPath() {
        let e = map("https://example.com/app", ["a/b.html"])
        XCTAssertEqual(e.first?.url, url("https://example.com/app/a/b.html"))
    }

    func testMultipleEntriesKeepOrder() {
        let e = map("https://example.com", ["index.html", "a.css", "img/logo.png"])
        XCTAssertEqual(e.map(\.localPath), ["index.html", "a.css", "img/logo.png"])
    }
}
