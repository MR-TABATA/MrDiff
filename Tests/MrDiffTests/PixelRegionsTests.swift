import XCTest
@testable import MrDiffCore

/// 違う画素を塊にまとめる規則を縛る。
final class PixelRegionsTests: XCTestCase {

    /// 文字で絵を描く: `#` が違う画素。
    private func mask(_ rows: [String]) -> ([UInt8], Int, Int) {
        let h = rows.count, w = rows[0].count
        var m = [UInt8](repeating: 0, count: w * h)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" { m[y * w + x] = 1 }
        }
        return (m, w, h)
    }

    func testNoDifferenceNoRegions() {
        let (m, w, h) = mask(["....", "....", "...."])
        XCTAssertEqual(differenceRegions(mask: m, width: w, height: h), [])
    }

    func testEightConnectedPixelsAreOneRegion() {
        let (m, w, h) = mask([
            "#.......",
            ".#......",
            "..#.....",
            "........",
        ])
        let r = differenceRegions(mask: m, width: w, height: h, near: 0)
        XCTAssertEqual(r, [PixelRegion(x: 0, y: 0, width: 3, height: 3, count: 3)])
    }

    /// 離れた塊は別。`near` を超えていればまとめない。
    func testFarApartStaySeparateAndAreOrderedTopLeftFirst() {
        let (m, w, h) = mask([
            "........#",
            ".........",
            ".........",
            "##.......",
        ])
        let r = differenceRegions(mask: m, width: w, height: h, near: 1)
        XCTAssertEqual(r, [
            PixelRegion(x: 8, y: 0, width: 1, height: 1, count: 1),
            PixelRegion(x: 0, y: 3, width: 2, height: 1, count: 2),
        ])
    }

    /// 隙間が `near` 以下なら 1 つにまとめる。数は足し、矩形は外接。
    func testNearbyRegionsMerge() {
        let (m, w, h) = mask([
            "##...##",
            ".......",
            ".......",
        ])
        XCTAssertEqual(differenceRegions(mask: m, width: w, height: h, near: 2).count, 2)
        let merged = differenceRegions(mask: m, width: w, height: h, near: 3)
        XCTAssertEqual(merged, [PixelRegion(x: 0, y: 0, width: 7, height: 1, count: 4)])
    }

    /// 既定の `near` は短辺 ÷ 100（最低 2）。
    func testDefaultNearScalesWithShortSide() {
        // 400 幅 × 4 高: 短辺 4 → near 2。隙間 2 はまとまり、隙間 3 は分かれる。
        var m = [UInt8](repeating: 0, count: 400 * 4)
        m[0] = 1; m[3] = 1          // 隙間 2
        m[100] = 1; m[104] = 1      // 隙間 3
        let r = differenceRegions(mask: m, width: 400, height: 4)
        XCTAssertEqual(r.count, 3)
    }
}
