import Foundation

/// バイナリ 2 つを比べて、**違うかどうかと、どこが**を答える。
///
/// ```
/// Binary files differ — 47 regions, first at 0x1A3F
/// ```
///
/// ## 絵は出さない。16 進も並べない
///
/// 並べるのは 010 Editor や `radiff2` の仕事で、**無料 CLI は「違うかどうか」まで**
/// （CONCEPT §4.1）。ここで出すのは「いくつの塊が」「最初はどこか」だけ。
///
/// ## 全部のバイトを見ない
///
/// まず**ブロックごとのハッシュ**で突き合わせ、**食い違ったブロックの中だけ**を 1 バイトずつ見る。
/// 10GB のうち 5 バイトしか違わないファイルでも、費用は「違った量」に比例する
/// （README の Speed 節がこれ）。同じブロックは触らない。
///
/// ## 長さが違うとき
///
/// **共通部分だけを比べ、余りは「余り」として言う。** 途中に 1 バイト挿入されただけで
/// 以降が全部ずれる、という結果を「全部違う」と出すのは正しいが役に立たない ―― ずれたのか
/// 書き換わったのかは、この道具の答えの外。**そう言えることだけ言う。**
public enum BinaryDiff {

    /// 突き合わせるブロックの大きさ。
    ///
    /// 64 KiB は「1 回の `memcmp` が十分長く、かつ食い違ったときに舐め直す量が小さい」
    /// あたり。**変えても答えは変わらない**（速さだけが変わる）。
    public static let blockSize = 64 << 10

    public struct Region: Equatable {
        /// 違いが始まる位置（両方の先頭からのバイト数）。
        public let offset: Int
        /// 続いた長さ。
        public let length: Int
    }

    public struct Result: Equatable {
        /// 違っている塊。**隣り合うバイトは 1 つにまとめる。**
        public let regions: [Region]
        /// 共通部分（短いほうの長さ）で、違っていたバイト数。
        public let differingBytes: Int
        /// それぞれの長さ。
        public let sizeA: Int
        public let sizeB: Int

        public var isIdentical: Bool { regions.isEmpty && sizeA == sizeB }
        /// 片方が長い分。0 なら長さは同じ。
        public var extraBytes: Int { abs(sizeA - sizeB) }
        public var first: Region? { regions.first }
    }

    /// 比べる。
    public static func compare(_ a: Data, _ b: Data, blockSize: Int = blockSize) -> Result {
        let common = min(a.count, b.count)
        var regions: [Region] = []
        var differing = 0

        a.withUnsafeBytes { rawA in
            b.withUnsafeBytes { rawB in
                let pa = rawA.bindMemory(to: UInt8.self).baseAddress
                let pb = rawB.bindMemory(to: UInt8.self).baseAddress
                guard let pa, let pb else { return }

                // いま開いている塊（違いが続いている途中なら、その始まり）。
                var openStart: Int? = nil
                var block = 0
                while block < common {
                    let size = min(blockSize, common - block)
                    // **ここが先読み。** 同じブロックなら中を見ない。
                    if memcmp(pa + block, pb + block, size) == 0 {
                        if let s = openStart {
                            regions.append(Region(offset: s, length: block - s))
                            openStart = nil
                        }
                        block += size
                        continue
                    }
                    // 食い違ったブロックの中だけ、1 バイトずつ。
                    for i in block..<(block + size) {
                        if pa[i] != pb[i] {
                            differing += 1
                            if openStart == nil { openStart = i }
                        } else if let s = openStart {
                            regions.append(Region(offset: s, length: i - s))
                            openStart = nil
                        }
                    }
                    block += size
                }
                // **ブロックの境界で塊を切らない。** 最後まで開いていたら、そこで閉じる。
                if let s = openStart {
                    regions.append(Region(offset: s, length: common - s))
                }
            }
        }

        return Result(regions: regions, differingBytes: differing,
                      sizeA: a.count, sizeB: b.count)
    }

    /// `0x1A3F` の形。**10 進では出さない**（バイナリを見る人は 16 進で数える）。
    public static func hex(_ offset: Int) -> String {
        "0x" + String(offset, radix: 16, uppercase: true)
    }
}
