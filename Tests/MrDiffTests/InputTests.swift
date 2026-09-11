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

    /// **http(s) 以外は URL にしない。** 黙って別のものを取りに行くより、開けないと言うほうがよい。
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
