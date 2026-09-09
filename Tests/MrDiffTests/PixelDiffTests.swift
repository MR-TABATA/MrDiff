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

    /// **現状**: 大きい画像では、1 画素の違いが `0.0%` と表示される。
    /// 「同じ」と読めてしまう。**割合ではなく数や領域で言うべき**、という宿題。
    ///
    /// 小さい画像では起きない（40x30 なら 1/1200 = 0.083% → `0.1`）ので、
    /// ファイルではなく比率を直に置いて固定する。
    func test_現状_大きい画像だと1画素の違いが0パーセントになる() {
        let d = PixelDiff(changed: 1, total: 120_000, first: Point(x: 0, y: 0))
        XCTAssertEqual(String(format: "%.1f", d.fraction * 100), "0.0",
                       "400x300 で 1 画素違うと、表示上は 0.0% になる")
        XCTAssertEqual(d.changed, 1, "実際には 1 画素違う")
    }

    /// 4K のスクリーンショットだと、さらに見えなくなる。
    func test_現状_4Kだと1画素の違いはもっと消える() {
        let d = PixelDiff(changed: 1, total: 3840 * 2160, first: Point(x: 0, y: 0))
        XCTAssertEqual(String(format: "%.1f", d.fraction * 100), "0.0")
    }

    func test_0画素なら_identical() {
        let r = comparePixels(a: [], sizeA: Size(width: 0, height: 0),
                              b: [], sizeB: Size(width: 0, height: 0), bytesPerPixel: 4)
        XCTAssertEqual(r, .identical)
    }
}
