import XCTest
@testable import MrDiffCore

/// `--json` の形を固定する。**公開した後は変えられない**ので、形が動いたらここが落ちる。
///
/// 1 種類につき「同じ」と「違う」の 2 本。加えて、壊れた JSON を出していた穴
/// （エスケープ）と、緩めて比べたときの印を縛る。
final class JSONOutputTests: XCTestCase {

    private func parse(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - 共通

    func testEveryKindCarriesKindAndResult() {
        let text = JSONOutput.text(compareText(TextSource(text: "a\n"), TextSource(text: "a\n")))
        let image = JSONOutput.image(.identical, tolerance: 0, ignoreAlpha: false)
        let binary = JSONOutput.binary(BinaryDiff.compare(Data([1, 2]), Data([1, 2])))
        let site = JSONOutput.site(SiteDiff(rows: []))
        let tree = JSONOutput.tree(TreeDiff(rows: []))
        for (o, kind) in [(text, "text"), (image, "image"), (binary, "binary"), (site, "site"), (tree, "tree")] {
            XCTAssertEqual(o["kind"] as? String, kind)
            XCTAssertEqual(o["result"] as? String, "identical", kind)
        }
    }

    func testEncodeIsOneLineWithSortedKeys() {
        let s = JSONOutput.encode(["b": 1, "a": 2])
        XCTAssertEqual(s, #"{"a":2,"b":1}"#)
        XCTAssertFalse(s.contains("\n"))
    }

    // MARK: - テキスト

    func testTextDiffer() {
        let d = compareText(TextSource(text: "one\ntwo\n"), TextSource(text: "one\nthree\nfour\n"))
        let s = JSONOutput.encode(JSONOutput.text(d))
        // changed は replace ハンクの max(左, 右)。1 行消して 2 行足すと changed:2
        XCTAssertEqual(s, #"{"added":0,"changed":2,"kind":"text","removed":0,"result":"differ"}"#)
    }

    // MARK: - 画像

    func testImageDiffer() {
        let d = PixelDiff(changed: 3, total: 100, first: Point(x: 4, y: 5), maxGap: 7)
        let s = JSONOutput.encode(JSONOutput.image(.differ(d), tolerance: 0, ignoreAlpha: false))
        XCTAssertEqual(s, #"{"changed":3,"first":{"x":4,"y":5},"fraction":0.03,"kind":"image","max_gap":7,"result":"differ","total":100}"#)
    }

    func testImageSizeMismatch() {
        let r = ImageComparison.sizeMismatch(Size(width: 40, height: 30), Size(width: 41, height: 30))
        let s = JSONOutput.encode(JSONOutput.image(r, tolerance: 0, ignoreAlpha: false))
        XCTAssertEqual(s, #"{"a":{"height":30,"width":40},"b":{"height":30,"width":41},"kind":"image","result":"size_mismatch"}"#)
    }

    /// 全体の色の差は、あるときだけ `tone_shift`（B − A のチャンネルごとの平均、小数 1 桁）。
    func testImageToneShift() {
        let tone = ToneDifference(mean: [21.26, 18.57, 17.71])
        let s = JSONOutput.encode(JSONOutput.image(.identical, tolerance: 0, ignoreAlpha: false, tone: tone))
        XCTAssertEqual(s, #"{"kind":"image","result":"identical","tone_shift":[21.3,18.6,17.7]}"#)
    }

    /// **緩めて比べたら JSON にもそう書く。**既定のときはキー自体を出さない。
    func testImageRelaxationsAppearOnlyWhenUsed() {
        let strict = JSONOutput.image(.identical, tolerance: 0, ignoreAlpha: false)
        XCTAssertNil(strict["tolerance"])
        XCTAssertNil(strict["ignore_alpha"])

        let s = JSONOutput.encode(JSONOutput.image(.identical, tolerance: 2, ignoreAlpha: true))
        XCTAssertEqual(s, #"{"ignore_alpha":true,"kind":"image","result":"identical","tolerance":2}"#)
    }

    // MARK: - バイナリ

    func testBinaryDiffer() {
        var b = Data(repeating: 0, count: 100)
        b[10] = 1
        let d = BinaryDiff.compare(Data(repeating: 0, count: 100), b)
        let s = JSONOutput.encode(JSONOutput.binary(d))
        XCTAssertEqual(s, #"{"differing_bytes":1,"first":{"offset":10},"kind":"binary","regions":1,"result":"differ","size_a":100,"size_b":100}"#)
    }

    /// 長さだけ違う ＝ 違う箇所は無いが identical ではない。first は null。
    func testBinaryLengthOnly() {
        let d = BinaryDiff.compare(Data(repeating: 0, count: 10), Data(repeating: 0, count: 12))
        let o = JSONOutput.binary(d)
        XCTAssertEqual(o["result"] as? String, "differ")
        XCTAssertTrue(o["first"] is NSNull)
        XCTAssertEqual(o["regions"] as? Int, 0)
    }

    // MARK: - site

    private func entry(_ p: String) -> SiteMap.Entry {
        .init(localPath: p, url: URL(string: "https://x/\(p)")!)
    }

    func testSiteDifferAndRows() {
        let d = SiteDiff(rows: [
            .init(entry: entry("a.html"), status: .identical),
            .init(entry: entry("b.html"), status: .changed),
            .init(entry: entry("c.html"), status: .missing),
        ])
        let s = JSONOutput.encode(JSONOutput.site(d))
        XCTAssertEqual(s, #"{"changed":1,"errors":0,"files":3,"in_sync":false,"kind":"site","missing":1,"result":"differ","rows":[{"path":"a.html","status":"identical"},{"path":"b.html","status":"changed"},{"path":"c.html","status":"missing"}]}"#)
    }

    /// 違いは無いが確認できなかったものがある ＝ identical でも differ でもなく error。
    func testSiteErrorOnlyIsNotIdentical() {
        let d = SiteDiff(rows: [
            .init(entry: entry("a.html"), status: .identical),
            .init(entry: entry("b.html"), status: .error("HTTP 500")),
        ])
        let o = JSONOutput.site(d)
        XCTAssertEqual(o["result"] as? String, "error")
        XCTAssertEqual(o["in_sync"] as? Bool, false)
        XCTAssertEqual(o["errors"] as? Int, 1)
    }

    // MARK: - tree

    func testTreeDiffer() {
        let d = TreeDiff(rows: [
            .init(path: "same", status: .identical),
            .init(path: "conf", status: .changed),
            .init(path: "new.html", status: .onlyLeft),
            .init(path: "left-over.sql", status: .onlyRight),
        ])
        let s = JSONOutput.encode(JSONOutput.tree(d))
        XCTAssertEqual(s, #"{"changed":1,"files":4,"in_sync":false,"kind":"tree","only_local":1,"only_remote":1,"result":"differ","rows":[{"path":"same","status":"identical"},{"path":"conf","status":"changed"},{"path":"new.html","status":"only_local"},{"path":"left-over.sql","status":"only_remote"}]}"#)
    }

    // MARK: - 穴

    /// 手書きの連結は `"` しか逃がしていなかった。`\`・改行・`"` を含むパスでも読める JSON を出す。
    func testPathsWithAwkwardCharactersStayValidJSON() {
        let nasty = "dir\\name \"quoted\"\nnext"
        let d = TreeDiff(rows: [.init(path: nasty, status: .changed)])
        let s = JSONOutput.encode(JSONOutput.tree(d))
        let rows = parse(s)["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["path"] as? String, nasty)
    }

    /// URL のリダイレクトは、飛ばされたときだけ `redirected` に載る。`/` はエスケープしない。
    func testRedirectsOnlyWhenPresent() {
        let d = compareText(TextSource(text: "a\n"), TextSource(text: "a\n"))
        XCTAssertNil(JSONOutput.text(d)["redirected"])
        let s = JSONOutput.encode(JSONOutput.text(d, redirects: [.init(from: "http://a/x", to: "https://a/x/")]))
        XCTAssertEqual(s, #"{"kind":"text","redirected":[{"from":"http://a/x","to":"https://a/x/"}],"result":"identical"}"#)
    }
}
