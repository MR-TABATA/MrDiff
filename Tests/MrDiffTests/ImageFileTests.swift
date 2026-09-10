import XCTest
@testable import MrDiffCore

/// **本物の画像ファイルで確かめる。** `PixelDiffTests` は合成した配列で判定だけを見るが、
/// 読み込み・色空間の正規化・形式の違いは、実ファイルを通さないと出ない。
///
/// `Fixtures/` は 40x30 の小さな絵（ヘッダ帯 ＋ ボタン）。全部で 48KB。
///
/// **この中の何本かは「いまの答え」を固定したもので、「正しい答え」ではない。**
/// 名前に `現状` と付けてある。直すときはテストごと書き換える ―― そのとき
/// 「意図して変えた」と分かるように、いま記録しておく。

final class ImageFileTests: XCTestCase {

    private func url(_ name: String) throws -> URL {
        let u = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        return try XCTUnwrap(u, "fixture が見つからない: \(name)")
    }

    private func compare(_ a: String, _ b: String) throws -> ImageComparison {
        try compareImages(try url(a), try url(b))
    }

    // MARK: - 読み込み

    func test_PNGを読める() throws {
        let img = try loadImage(at: try url("same-a.png"))
        XCTAssertEqual(img.size, Size(width: 40, height: 30))
        XCTAssertEqual(img.bytesPerPixel, 4)
        XCTAssertEqual(img.pixels.count, 40 * 30 * 4)
    }

    func test_JPEGも読める() throws {
        let img = try loadImage(at: try url("reencode.jpg"))
        XCTAssertEqual(img.size, Size(width: 40, height: 30))
        XCTAssertEqual(img.bytesPerPixel, 4, "形式が違っても RGBA へ正規化される")
    }

    func test_画像でないファイルは投げる() throws {
        // Package.swift はこのバンドルに入らないので、テスト自身のソースを使う
        let notImage = URL(fileURLWithPath: #filePath)
        XCTAssertThrowsError(try loadImage(at: notImage))
    }

    // MARK: - 比較

    func test_同じ画像はidentical() throws {
        XCTAssertEqual(try compare("same-a.png", "same-b.png"), .identical)
    }

    func test_寸法が違えばsizeMismatch() throws {
        XCTAssertEqual(try compare("size-a.png", "size-b.png"),
                       .sizeMismatch(Size(width: 40, height: 30), Size(width: 36, height: 30)))
    }

    func test_1画素だけ違う() throws {
        guard case .differ(let d) = try compare("tiny-a.png", "tiny-b.png") else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertEqual(d.changed, 1)
        XCTAssertEqual(d.first, Point(x: 30, y: 25))
    }

    /// ボタン（16x8）を 1px 下げた。上下に 16x1 の帯が 2 本 ＝ 32 画素。
    func test_1px下げると帯が2本_32画素() throws {
        guard case .differ(let d) = try compare("shift-a.png", "shift-b.png") else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertEqual(d.changed, 32, "16x1 の帯が上下に 1 本ずつ")
        XCTAssertEqual(d.first, Point(x: 8, y: 10), "消えたほうの帯の左上")
    }

    // MARK: - いまの答えを固定したもの（正しい答えではない）

    /// **現状**: 見た目は完全に同じなのに、全画素が「違う」になる。
    /// アルファを 255→254 にしただけ。スクリーンショットを比べる人が欲しい答えではない。
    /// 直すなら `--ignore-alpha` か、色だけ比べる既定にする。
    func test_現状_アルファだけ違うと100パーセント() throws {
        guard case .differ(let d) = try compare("alpha-a.png", "alpha-b.png") else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertEqual(d.changed, d.total, "全画素が違う判定になる")
    }

    /// **現状**: 同じ絵を JPEG にしただけで、大量の画素が「違う」になる。
    /// JPEG は不可逆なので微小な差が全体に散る。目で見て同じものを「違う」と言っている。
    /// 直すなら `--tolerance`（1 チャンネルあたり ±N までは同じとみなす）。
    ///
    /// **枚数は環境で変わりうるので、割合の下限だけを見る。**
    func test_現状_JPEG再エンコードで大量に違う() throws {
        guard case .differ(let d) = try compare("reencode.png", "reencode.jpg") else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertGreaterThan(d.fraction, 0.1, "1 割以上が違う判定になる（見た目は同じ）")
    }

    /// なお「1 画素の違いが `0.0%` と出た」症状は、**この fixture では再現しなかった。**
    /// 40x30 なら 1/1200 = 0.083% で `0.1` と出るため。割合が消えるのは画像が大きいとき
    /// （400x300 で 1/120000 = 0.00083% → `0.0`）。純関数側の `PixelDiffTests` で固定してある。
}
