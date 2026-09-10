import XCTest
@testable import MrDiffCore

/// 判定を変えるときはここを見る。**実データで一度やらかした症状を 1 件ずつ固定する**
/// 方針は MrEditor / MrShip と同じ。いまはまだ想定の分だけ。

final class PixelDiffTests: XCTestCase {

    /// 2x2 の RGBA を組む補助
    private func buf(_ pixels: [[UInt8]]) -> [UInt8] { pixels.flatMap { $0 } }
    private let size2x2 = Size(width: 2, height: 2)
    private let black: [UInt8] = [0, 0, 0, 255]
    private let white: [UInt8] = [255, 255, 255, 255]

    func test_同じなら_identical() {
        let a = buf([black, white, white, black])
        let r = comparePixels(a: a, sizeA: size2x2, b: a, sizeB: size2x2, bytesPerPixel: 4)
        XCTAssertEqual(r, .identical)
    }

    func test_寸法が違えば_それ以上比べない() {
        let a = buf([black, white, white, black])
        let b = buf([black, white])
        let r = comparePixels(a: a, sizeA: size2x2,
                              b: b, sizeB: Size(width: 2, height: 1), bytesPerPixel: 4)
        XCTAssertEqual(r, .sizeMismatch(Size(width: 2, height: 2), Size(width: 2, height: 1)))
    }

    func test_違う画素の数と割合() {
        let a = buf([black, white, white, black])
        let b = buf([black, black, white, black])   // 1 画素だけ違う
        guard case .differ(let d) = comparePixels(a: a, sizeA: size2x2, b: b, sizeB: size2x2, bytesPerPixel: 4) else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertEqual(d.changed, 1)
        XCTAssertEqual(d.total, 4)
        XCTAssertEqual(d.fraction, 0.25)
    }

    func test_最初の差分は左上から走査した順() {
        let a = buf([black, black, black, black])
        let b = buf([black, black, black, white])   // 右下だけ違う
        guard case .differ(let d) = comparePixels(a: a, sizeA: size2x2, b: b, sizeB: size2x2, bytesPerPixel: 4) else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertEqual(d.first, Point(x: 1, y: 1))
    }

    /// 透明度だけが違う場合も差分。**見た目が同じでもデータは違う**ので、
    /// 「違う」と答えるほうが嘘にならない。
    func test_アルファだけ違っても差分() {
        let a = buf([[0, 0, 0, 255], black, black, black])
        let b = buf([[0, 0, 0, 128], black, black, black])
        guard case .differ(let d) = comparePixels(a: a, sizeA: size2x2, b: b, sizeB: size2x2, bytesPerPixel: 4) else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertEqual(d.changed, 1)
        XCTAssertEqual(d.first, Point(x: 0, y: 0))
    }

    /// **直した症状**: 大きい画像で 1 画素だけ違うと `0.0%` と出て、「同じ」と読めた。
    /// 割合が丸めて消える大きさでは、**割合を出さない**（数は消えないので数で言う）。
    ///
    /// 小さい画像では起きない（40x30 なら 1/1200 = 0.083% → `0.1`）ので、
    /// ファイルではなく比率を直に置いて固定する。
    func test_大きい画像では割合を出さない() {
        let d = PixelDiff(changed: 1, total: 120_000, first: Point(x: 0, y: 0))
        XCTAssertNil(d.displayPercent, "400x300 で 1 画素 ―― 出せば 0.0% になる")
        XCTAssertEqual(d.changed, 1, "数のほうは消えない")
        XCTAssertEqual(d.total, 120_000)
    }

    /// 4K のスクリーンショットだと、さらに小さくなる。それでも数は残る。
    func test_4Kでも割合を出さない() {
        let d = PixelDiff(changed: 1, total: 3840 * 2160, first: Point(x: 0, y: 0))
        XCTAssertNil(d.displayPercent)
        XCTAssertEqual(d.changed, 1)
    }

    /// 丸めて残るなら、割合は出す。
    func test_丸めて残るなら割合を出す() {
        XCTAssertEqual(PixelDiff(changed: 1, total: 1_200,
                                 first: Point(x: 0, y: 0)).displayPercent, "0.1",
                       "40x30 で 1 画素 = 0.083% → 0.1")
        XCTAssertEqual(PixelDiff(changed: 300, total: 1_200,
                                 first: Point(x: 0, y: 0)).displayPercent, "25.0")
        XCTAssertEqual(PixelDiff(changed: 1_200, total: 1_200,
                                 first: Point(x: 0, y: 0)).displayPercent, "100.0")
    }

    /// 境目は「%.1f が 0.0 になるかどうか」＝ 0.05%。またぐ両側を固定する。
    func test_割合を出すかの境目() {
        XCTAssertNil(PixelDiff(changed: 4, total: 10_000,
                               first: Point(x: 0, y: 0)).displayPercent, "0.04% は出さない")
        XCTAssertEqual(PixelDiff(changed: 6, total: 10_000,
                                 first: Point(x: 0, y: 0)).displayPercent, "0.1",
                       "0.06% は 0.1 として出す")
    }

    // MARK: - つまみ

    /// `--ignore-alpha` は**アルファだけの差**に効く。合成配列なら、実ファイルと違って
    /// 「アルファだけ」を正確に作れる（実ファイルの fixture は RGB もずれていた）。
    func test_透明度を見なければアルファだけの差は消える() {
        let a = buf([[0, 0, 0, 255], black, black, black])
        let b = buf([[0, 0, 0, 128], black, black, black])
        XCTAssertEqual(comparePixels(a: a, sizeA: size2x2, b: b, sizeB: size2x2,
                                     bytesPerPixel: 4, ignoreAlpha: true),
                       .identical)
    }

    /// 色が違えば、透明度を見なくても差分。**落とすのはアルファだけ。**
    func test_透明度を見なくても色の差は残る() {
        let a = buf([[10, 0, 0, 255], black, black, black])
        let b = buf([[20, 0, 0, 128], black, black, black])
        guard case .differ(let d) = comparePixels(a: a, sizeA: size2x2, b: b, sizeB: size2x2,
                                                  bytesPerPixel: 4, ignoreAlpha: true) else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertEqual(d.changed, 1)
    }

    /// RGBA でない形では ignoreAlpha は効かせない。**どれがアルファか決まらないため。**
    func test_RGBAでなければ透明度の指定は効かない() {
        let a: [UInt8] = [10, 0, 0, 20, 0, 0]      // 3 バイト/画素 が 2 つ
        let b: [UInt8] = [10, 0, 0, 21, 0, 0]
        let size = Size(width: 2, height: 1)
        guard case .differ(let d) = comparePixels(a: a, sizeA: size, b: b, sizeB: size,
                                                  bytesPerPixel: 3, ignoreAlpha: true) else {
            return XCTFail("differ が返るはず")
        }
        XCTAssertEqual(d.changed, 1, "3 本目を黙って落としたりしない")
    }

    /// tolerance は**チャンネルごとの絶対差**で見る。境目の両側を固定する。
    func test_toleranceの境目() {
        let a = buf([[100, 100, 100, 255], black, black, black])
        let b = buf([[102, 100, 100, 255], black, black, black])   // R だけ +2
        XCTAssertEqual(comparePixels(a: a, sizeA: size2x2, b: b, sizeB: size2x2,
                                     bytesPerPixel: 4, tolerance: 2),
                       .identical, "±2 なら同じ")
        guard case .differ(let d) = comparePixels(a: a, sizeA: size2x2, b: b, sizeB: size2x2,
                                                  bytesPerPixel: 4, tolerance: 1) else {
            return XCTFail("±1 では差分のまま")
        }
        XCTAssertEqual(d.changed, 1)
    }

    /// 既定は 0。**つまみを付けても、既定の答えは変えない。**
    func test_既定は厳密なまま() {
        let a = buf([[100, 100, 100, 255], black, black, black])
        let b = buf([[101, 100, 100, 255], black, black, black])
        guard case .differ(let d) = comparePixels(a: a, sizeA: size2x2, b: b, sizeB: size2x2,
                                                  bytesPerPixel: 4) else {
            return XCTFail("1 違えば差分")
        }
        XCTAssertEqual(d.changed, 1)
    }

    func test_0画素なら_identical() {
        let r = comparePixels(a: [], sizeA: Size(width: 0, height: 0),
                              b: [], sizeB: Size(width: 0, height: 0), bytesPerPixel: 4)
        XCTAssertEqual(r, .identical)
    }
}
