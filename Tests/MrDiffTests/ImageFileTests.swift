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

    private func compare(_ a: String, _ b: String,
                         tolerance: Int = 0,
                         ignoreAlpha: Bool = false) throws -> ImageComparison {
        try compareImages(try url(a), try url(b),
                          tolerance: tolerance, ignoreAlpha: ignoreAlpha)
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

    // MARK: - 微小な差を「同じ」とみなすつまみ

    /// 既定は**厳密**。1 でも違えば違う。ここは変えていない。
    func test_既定では微小な差も差分() throws {
        guard case .differ(let d) = try compare("alpha-a.png", "alpha-b.png") else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertEqual(d.changed, d.total, "全画素が違う判定になる")
    }

    /// **測って分かったこと**: この fixture は「アルファだけ 255→254」ではなかった。
    /// **RGB も 1 ずつずれている**（PNG の書き出しで前乗算の丸めが入ったと思われる）。
    ///
    /// なので `--ignore-alpha` だけでは 0 にならない ―― 1200 → 960 に減るだけ。
    /// 直すのは `--tolerance=1` のほう。**言い当てていたのは片方だけだった。**
    func test_透明度を見なくても_この差は消えない() throws {
        guard case .differ(let d) = try compare("alpha-a.png", "alpha-b.png",
                                                ignoreAlpha: true) else {
            return XCTFail("RGB もずれているので differ のまま")
        }
        XCTAssertEqual(d.changed, 960, "アルファを外しても RGB のずれが残る")
    }

    /// ±1 まで許せば、この 2 枚は同じ。
    func test_tolerance1で一致する() throws {
        XCTAssertEqual(try compare("alpha-a.png", "alpha-b.png", tolerance: 1), .identical)
    }

    /// JPEG は不可逆なので、微小な差が全体に散る。既定では 1 割以上が「違う」になる。
    /// **枚数は環境で変わりうるので、割合の下限だけを見る。**
    func test_JPEG再エンコードは既定では大量に違う() throws {
        guard case .differ(let d) = try compare("reencode.png", "reencode.jpg") else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertGreaterThan(d.fraction, 0.1, "1 割以上が違う判定になる（見た目は同じ）")
    }

    /// tolerance を上げれば減る。**ただし ±1 や ±2 では消えない。**
    /// 測った最大差は R31 G9 B36 で、全部を飲み込むには ±36 が要る。
    /// つまりこのつまみは JPEG を「同じ」にする道具ではなく、**どこまで散っているかを
    /// 測る道具**。枚数は環境で動きうるので、単調に減ることだけを見る。
    func test_toleranceを上げると減る() throws {
        func changed(_ tol: Int) throws -> Int {
            guard case .differ(let d) = try compare("reencode.png", "reencode.jpg",
                                                    tolerance: tol) else { return 0 }
            return d.changed
        }
        let zero = try changed(0), one = try changed(1), five = try changed(5)
        XCTAssertGreaterThan(zero, one)
        XCTAssertGreaterThan(one, five)
        XCTAssertGreaterThan(five, 0, "±5 ではまだ残る")
    }

    /// なお「1 画素の違いが `0.0%` と出た」症状は、**この fixture では再現しなかった。**
    /// 40x30 なら 1/1200 = 0.083% で `0.1` と出るため。割合が消えるのは画像が大きいとき
    /// （400x300 で 1/120000 = 0.00083% → `0.0`）。純関数側の `PixelDiffTests` で固定してある。
}
