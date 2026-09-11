import XCTest
@testable import MrDiffCore

/// バイナリ比較の試験。
///
/// **本丸はブロックの境界。** 先読みのために 64 KiB ごとに突き合わせるので、
/// 境界をまたぐ違いを 2 箇所と数えてしまう実装になりやすい。そこを厚く縛る。
final class BinaryDiffTests: XCTestCase {

    private func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    private func filled(_ n: Int, _ v: UInt8 = 0xAA) -> Data {
        Data(repeating: v, count: n)
    }

    // MARK: - 基本

    func testIdentical() {
        let d = BinaryDiff.compare(filled(1000), filled(1000))
        XCTAssertTrue(d.isIdentical)
        XCTAssertEqual(d.regions.count, 0)
        XCTAssertEqual(d.differingBytes, 0)
    }

    func testBothEmpty() {
        let d = BinaryDiff.compare(Data(), Data())
        XCTAssertTrue(d.isIdentical)
    }

    func testOneByteDiffers() {
        var b = filled(1000)
        b[500] = 0x01
        let d = BinaryDiff.compare(filled(1000), b)
        XCTAssertEqual(d.regions, [.init(offset: 500, length: 1)])
        XCTAssertEqual(d.differingBytes, 1)
        XCTAssertFalse(d.isIdentical)
    }

    /// 隣り合うバイトは**1 つの塊**にまとめる。
    func testAdjacentBytesAreOneRegion() {
        var b = filled(1000)
        for i in 100..<110 { b[i] = 0x01 }
        let d = BinaryDiff.compare(filled(1000), b)
        XCTAssertEqual(d.regions, [.init(offset: 100, length: 10)])
        XCTAssertEqual(d.differingBytes, 10)
    }

    func testSeparateRegions() {
        var b = filled(1000)
        b[10] = 1; b[11] = 1
        b[900] = 2
        let d = BinaryDiff.compare(filled(1000), b)
        XCTAssertEqual(d.regions, [.init(offset: 10, length: 2), .init(offset: 900, length: 1)])
        XCTAssertEqual(d.differingBytes, 3)
    }

    // MARK: - ブロックの境界（本丸）

    /// 境界をまたぐ違いは **1 箇所**。2 つに割ってはいけない。
    func testRegionSpanningBlockBoundaryIsOne() {
        let block = 64
        var a = filled(block * 3)
        var b = a
        for i in (block - 2)..<(block + 2) { b[i] = 0x01 }
        _ = a
        a = filled(block * 3)
        let d = BinaryDiff.compare(a, b, blockSize: block)
        XCTAssertEqual(d.regions, [.init(offset: block - 2, length: 4)])
    }

    /// 最後のブロックの末尾まで違っていても、閉じ忘れない。
    func testRegionAtTheVeryEnd() {
        let block = 64
        var b = filled(block * 2)
        for i in (block * 2 - 3)..<(block * 2) { b[i] = 0x01 }
        let d = BinaryDiff.compare(filled(block * 2), b, blockSize: block)
        XCTAssertEqual(d.regions, [.init(offset: block * 2 - 3, length: 3)])
    }

    /// ブロックの大きさを変えても**答えは変わらない**（速さだけが変わる）。
    func testBlockSizeDoesNotChangeTheAnswer() {
        var b = filled(5000)
        for i in [0, 63, 64, 65, 1000, 4999] { b[i] = 0x01 }
        let small = BinaryDiff.compare(filled(5000), b, blockSize: 16)
        let large = BinaryDiff.compare(filled(5000), b, blockSize: 4096)
        XCTAssertEqual(small.regions, large.regions)
        XCTAssertEqual(small.differingBytes, large.differingBytes)
    }

    // MARK: - 長さが違う

    /// **共通部分だけを比べ、余りは余りとして持つ。**
    func testDifferentLengthsCompareOnlyTheCommonPart() {
        let a = filled(100)
        let b = filled(150)
        let d = BinaryDiff.compare(a, b)
        XCTAssertEqual(d.regions, [], "共通部分は同じなのに違いを数えている")
        XCTAssertEqual(d.extraBytes, 50)
        XCTAssertFalse(d.isIdentical, "長さが違うものを「同じ」と言ってはいけない")
    }

    func testDifferentLengthsWithDifferenceInCommonPart() {
        var a = filled(100)
        a[10] = 0x01
        let d = BinaryDiff.compare(a, filled(150))
        XCTAssertEqual(d.regions, [.init(offset: 10, length: 1)])
        XCTAssertEqual(d.extraBytes, 50)
    }

    func testEmptyAgainstNonEmpty() {
        let d = BinaryDiff.compare(Data(), filled(10))
        XCTAssertEqual(d.regions, [])
        XCTAssertEqual(d.extraBytes, 10)
        XCTAssertFalse(d.isIdentical)
    }

    // MARK: - 見せ方

    /// 位置は **16 進**で出す（バイナリを見る人は 16 進で数える）。
    func testHexOffset() {
        XCTAssertEqual(BinaryDiff.hex(0x1A3F), "0x1A3F")
        XCTAssertEqual(BinaryDiff.hex(0), "0x0")
    }
}
