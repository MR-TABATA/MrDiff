import XCTest
@testable import MrDiffCore

/// 入れ物（ファイル・URL・クリップボード）の試験。
///
/// **ネットワークは叩かない。** 叩く試験は、落ちたときに「実装が悪いのか回線が悪いのか」
/// が分からなくなる。ここで縛るのは**引数をどう読み替えるか**まで。
final class InputTests: XCTestCase {

    // MARK: - 引数の読み替え

    func testHTTPAndHTTPSAreURLs() {
        if case .url(let u) = Input.parse("https://example.com/a") {
            XCTAssertEqual(u.absoluteString, "https://example.com/a")
        } else { XCTFail("https を URL として読めていない") }

        if case .url = Input.parse("http://example.com/a") {} else { XCTFail("http が URL でない") }
    }

    /// **http(s) 以外のスキームは URL にも SSH にもしない、ファイル扱い。**
    /// 黙って別のものを取りに行くより、開けないと言うほうがよい。`://` を見て弾く
    /// （さもないと `s3:` などが host:path の SSH に化ける）。
    func testOtherSchemesAreFiles() {
        for arg in ["file:///etc/hosts", "ftp://example.com/a", "s3://bucket/key"] {
            if case .file = Input.parse(arg) {} else { XCTFail("\(arg) をファイル扱いにしていない") }
        }
    }

    func testPlainPathsAreFiles() {
        if case .file(let u) = Input.parse("notes.md") {
            XCTAssertEqual(u.lastPathComponent, "notes.md")
        } else { XCTFail("ファイルとして読めていない") }
    }

    /// 相対パスに http が**含まれる**だけのものを URL にしない。
    func testPathContainingHTTPIsStillAFile() {
        if case .file = Input.parse("./docs/http-notes.md") {} else { XCTFail("URL にしてしまった") }
    }

    // MARK: - 名前

    /// **URL は縮めない。** 読みにくさより、別の URL と取り違えるほうが困る。
    func testURLLabelIsNotShortened() {
        let long = "https://example.com/very/long/path/that/goes/on?and=on&and=on"
        XCTAssertEqual(Input.parse(long).label, long)
    }

    func testFileLabelIsTheName() {
        XCTAssertEqual(Input.parse("/tmp/a/b/notes.md").label, "notes.md")
    }

    // MARK: - SSH（host:/path）

    func testSSHRemote() {
        if case .ssh(let h, let p) = Input.parse("web01:/var/www/index.html") {
            XCTAssertEqual(h, "web01")
            XCTAssertEqual(p, "/var/www/index.html")
        } else { XCTFail("host:/path を SSH として読めていない") }
    }

    func testSSHWithUser() {
        if case .ssh(let h, let p) = Input.parse("deploy@example.com:app/config.yml") {
            XCTAssertEqual(h, "deploy@example.com")
            XCTAssertEqual(p, "app/config.yml")
        } else { XCTFail("user@host: を読めていない") }
    }

    /// **相対パスに : が入っただけのものを SSH と誤らない。**
    func testRelativePathWithColonIsAFile() {
        if case .file = Input.parse("./notes:draft.md") {} else { XCTFail("SSH にしてしまった（./ 始まり）") }
    }

    /// ホスト部に / があれば SSH ではない。
    func testPathWithColonDeepIsFile() {
        if case .file = Input.parse("some/dir:name/x") {} else { XCTFail("SSH にしてしまった（/ を含む）") }
    }

    /// http(s) は : があっても URL のまま（SSH に横取りさせない）。
    func testHTTPStaysURL() {
        if case .url = Input.parse("https://example.com:8080/a") {} else { XCTFail("URL でなくなった") }
    }

    /// : が無ければただのファイル。
    func testNoColonIsFile() {
        if case .file = Input.parse("index.html") {} else { XCTFail("ファイルでない") }
    }

    /// SSH の label は host:path をそのまま返す。
    func testSSHLabel() {
        XCTAssertEqual(Input.parse("web01:/etc/app.conf").label, "web01:/etc/app.conf")
    }

    // MARK: - 飛ばし先

    /// **末尾のスラッシュだけの違いは「飛ばされた」ではない。**
    /// これを出すと、本物の警告まで信用されなくなる。
    func testTrailingSlashIsNotARedirect() {
        XCTAssertTrue(sameDestination(URL(string: "https://example.com")!,
                                      URL(string: "https://example.com/")!))
    }

    func testRealRedirectsAreDifferent() {
        XCTAssertFalse(sameDestination(URL(string: "http://github.com")!,
                                       URL(string: "https://github.com/")!), "http→https は別")
        XCTAssertFalse(sameDestination(URL(string: "https://example.com/")!,
                                       URL(string: "https://example.com/ja/")!), "パスが別")
        XCTAssertFalse(sameDestination(URL(string: "https://example.com/a")!,
                                       URL(string: "https://example.com/a?x=1")!), "クエリが別")
        XCTAssertFalse(sameDestination(URL(string: "https://example.com")!,
                                       URL(string: "https://www.example.com")!), "ホストが別")
    }

    // MARK: - クリップボード

    /// 文字が入っていれば、そのまま読める。
    func testReadsTextFromClipboard() throws {
        #if canImport(AppKit)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString("こんにちは\nhello", forType: .string)
        let data = try readClipboard()
        XCTAssertEqual(String(data: data, encoding: .utf8), "こんにちは\nhello")
        #else
        throw XCTSkip("AppKit が無い")
        #endif
    }

    /// 空なら**空と言う**（0 バイトを返して「同じです」と言わない）。
    func testEmptyClipboardThrows() throws {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        XCTAssertThrowsError(try readClipboard()) { error in
            guard case InputError.emptyClipboard = error else {
                return XCTFail("別のエラー: \(error)")
            }
        }
        #else
        throw XCTSkip("AppKit が無い")
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif
