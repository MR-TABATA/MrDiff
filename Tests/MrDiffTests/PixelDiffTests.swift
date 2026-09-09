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

    func test_0画素なら_identical() {
        let r = comparePixels(a: [], sizeA: Size(width: 0, height: 0),
                              b: [], sizeB: Size(width: 0, height: 0), bytesPerPixel: 4)
        XCTAssertEqual(r, .identical)
    }
}
