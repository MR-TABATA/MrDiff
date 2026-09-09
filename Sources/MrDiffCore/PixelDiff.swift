import Foundation

/// 画像の比較。**画素の並びだけを見る純関数**で、読み込みも表示も知らない。
///
/// 分けてあるのは、ここが唯一テストできる場所だから ―― 画像ファイルを用意しなくても
/// 合成した配列で判定を固定できる。読み込み（`ImageLoading.swift`）は OS に依存し、
/// 表示は CLI には無い。

public struct Size: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct Point: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct PixelDiff: Equatable, Sendable {
    /// 違った画素の数
    public let changed: Int
    /// 全画素数
    public let total: Int
    /// 左上から走査して最初に違った位置
    public let first: Point

    public init(changed: Int, total: Int, first: Point) {
        self.changed = changed
        self.total = total
        self.first = first
    }

    /// 違った割合（0.0〜1.0）。`total` が 0 なら 0。
    public var fraction: Double {
        total == 0 ? 0 : Double(changed) / Double(total)
    }
}

/// 比較の結果。**3 つとも答え**で、どれも失敗ではない。
public enum ImageComparison: Equatable, Sendable {
    /// 1 画素も違わない
    case identical
    /// 寸法が違う。**これ以上は比べない** ―― 画素を突き合わせても意味が無いため
    case sizeMismatch(Size, Size)
    /// 違う
    case differ(PixelDiff)
}

/// 生の画素列を突き合わせる。
///
/// - Parameters:
///   - a, b: 画素の並び。**8 bit / チャンネル、行あたり `width * bytesPerPixel`** を前提。
///   - bytesPerPixel: 1 画素のバイト数（RGBA なら 4）
///
/// 寸法が違えば `sizeMismatch` を返す。**足りない側に合わせて比べたりはしない**
/// ―― 「はみ出した分は差分か」に答えが無く、どちらに決めても嘘になるため。
public func comparePixels(
    a: [UInt8], sizeA: Size,
    b: [UInt8], sizeB: Size,
    bytesPerPixel: Int
) -> ImageComparison {
    guard sizeA == sizeB else { return .sizeMismatch(sizeA, sizeB) }

    let total = sizeA.width * sizeA.height
    guard total > 0 else { return .identical }

    var changed = 0
    var first: Point? = nil

    for y in 0..<sizeA.height {
        let rowStart = y * sizeA.width * bytesPerPixel
        for x in 0..<sizeA.width {
            let i = rowStart + x * bytesPerPixel
            var same = true
            for c in 0..<bytesPerPixel where a[i + c] != b[i + c] {
                same = false
                break
            }
            if !same {
                changed += 1
                if first == nil { first = Point(x: x, y: y) }
            }
        }
    }

    guard let firstPoint = first else { return .identical }
    return .differ(PixelDiff(changed: changed, total: total, first: firstPoint))
}
