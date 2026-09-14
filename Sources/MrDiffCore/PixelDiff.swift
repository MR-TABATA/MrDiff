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
    /// 比べたチャンネルの中で、いちばん大きかった値の差（0〜255）。
    ///
    /// **既定（完全一致）を変えない代わりに、緩め方を教えるための数。**
    /// JPEG の再エンコードや前乗算の丸めで「見た目は同じなのに違う」と出たとき、
    /// `--tolerance=<この値>` なら同じになる、と言える。
    public let maxGap: Int

    public init(changed: Int, total: Int, first: Point, maxGap: Int = 0) {
        self.changed = changed
        self.total = total
        self.first = first
        self.maxGap = maxGap
    }

    /// 違った割合（0.0〜1.0）。`total` が 0 なら 0。
    public var fraction: Double {
        total == 0 ? 0 : Double(changed) / Double(total)
    }

    /// 人に見せる割合。**丸めて消えるなら nil。**
    ///
    /// 小数第 1 位まで出すので、400x300 の画像で 1 画素だけ違うと `0.0` になる。
    /// `0.0%` は「違う」ではなく**「同じ」と読める**ので、そこは割合で語らない。
    /// 数（`changed` / `total`）は消えないので、そちらで言う。
    public var displayPercent: String? {
        let p = fraction * 100
        guard p >= 0.05 else { return nil }   // %.1f が "0.0" になる境目
        return String(format: "%.1f", p)
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
///
/// - Parameters:
///   - tolerance: 1 チャンネルあたり **±この値までは同じとみなす**。既定 0（1 でも違えば違う）。
///     JPEG の再エンコードのように、目で見て同じでも値が散る比較のためのつまみ。
///   - ignoreAlpha: 透明度を見ない。**`bytesPerPixel == 4`（RGBA）のときだけ効く。**
///     既定は見る ―― 見た目が同じでもデータは違うので、「違う」と答えるほうが嘘にならない。
public func comparePixels(
    a: [UInt8], sizeA: Size,
    b: [UInt8], sizeB: Size,
    bytesPerPixel: Int,
    tolerance: Int = 0,
    ignoreAlpha: Bool = false
) -> ImageComparison {
    guard sizeA == sizeB else { return .sizeMismatch(sizeA, sizeB) }
    return compareOverlap(a: a, sizeA: sizeA, b: b, sizeB: sizeB, bytesPerPixel: bytesPerPixel,
                          offset: Point(x: 0, y: 0), tolerance: tolerance, ignoreAlpha: ignoreAlpha)
}

/// **ずらして比べる。** B を A の座標で `offset` の位置に置き、重なる矩形だけを比べる。
///
/// ヘッダーが 1 行ぶん違うスクリーンショット 2 枚は、そのままでは「全画素が違う」。
/// 右を 1 行ぶんずらして重ねれば「中身は同じか」が言える。寸法が違っても比べる
/// （重なる範囲の話なので）。重なりが無ければ `identical`（比べた画素が無い ── 呼ぶ側が
/// `total` を見て言う）。数は重なった範囲の画素数、`first` は A の座標。
public func comparePixels(
    a: [UInt8], sizeA: Size,
    b: [UInt8], sizeB: Size,
    bytesPerPixel: Int,
    offset: Point,
    tolerance: Int = 0,
    ignoreAlpha: Bool = false
) -> ImageComparison {
    compareOverlap(a: a, sizeA: sizeA, b: b, sizeB: sizeB, bytesPerPixel: bytesPerPixel,
                   offset: offset, tolerance: tolerance, ignoreAlpha: ignoreAlpha)
}

/// A の座標での、B と重なる矩形（x0, y0, x1, y1。x1 / y1 は含まない）。
func overlapRect(sizeA: Size, sizeB: Size, offset: Point) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
    (max(0, offset.x), max(0, offset.y), min(sizeA.width, sizeB.width + offset.x), min(sizeA.height, sizeB.height + offset.y))
}

private func compareOverlap(
    a: [UInt8], sizeA: Size, b: [UInt8], sizeB: Size, bytesPerPixel: Int,
    offset: Point, tolerance: Int, ignoreAlpha: Bool
) -> ImageComparison {
    let o = overlapRect(sizeA: sizeA, sizeB: sizeB, offset: offset)
    guard o.x1 > o.x0, o.y1 > o.y0 else { return .identical }
    let total = (o.x1 - o.x0) * (o.y1 - o.y0)

    var changed = 0
    var first: Point? = nil
    var maxGap = 0

    // RGBA の 4 本目がアルファ。それ以外の形では落とす対象が決まらないので、
    // ignoreAlpha は無視する（黙って 3 本目までにすると、別の意味になる）。
    let channels = (ignoreAlpha && bytesPerPixel == 4) ? 3 : bytesPerPixel

    for y in o.y0..<o.y1 {
        let rowA = y * sizeA.width * bytesPerPixel
        let rowB = (y - offset.y) * sizeB.width * bytesPerPixel
        for x in o.x0..<o.x1 {
            let i = rowA + x * bytesPerPixel
            let j = rowB + (x - offset.x) * bytesPerPixel
            // 画素の差 ＝ チャンネル差の最大。tolerance を超えたら「違う」。
            // 最大差は全画素で取る（途中で抜けない）── 「いくつ緩めれば同じか」を言うため。
            var gap = 0
            for c in 0..<channels {
                let d = abs(Int(a[i + c]) - Int(b[j + c]))
                if d > gap { gap = d }
            }
            if gap > tolerance {
                changed += 1
                if first == nil { first = Point(x: x, y: y) }
            }
            if gap > maxGap { maxGap = gap }
        }
    }

    guard let firstPoint = first else { return .identical }
    return .differ(PixelDiff(changed: changed, total: total, first: firstPoint, maxGap: maxGap))
}

/// 画素ごとの「違うか」。**判定は `comparePixels` と同じ規則**（tolerance / ignoreAlpha）。
///
/// 1 画素 1 バイト（0 = 同じ、1 = 違う）、行は `width` 個。寸法が違えば nil。
/// GUI が「どこが」を絵で見せるための材料で、答えの中身は数と同じ ── **見せる側が
/// 自分で比べ直さない**ために、判定側がここで出す。
public func differingPixels(
    a: [UInt8], sizeA: Size,
    b: [UInt8], sizeB: Size,
    bytesPerPixel: Int,
    tolerance: Int = 0,
    ignoreAlpha: Bool = false
) -> [UInt8]? {
    guard sizeA == sizeB else { return nil }
    return differingPixels(a: a, sizeA: sizeA, b: b, sizeB: sizeB, bytesPerPixel: bytesPerPixel,
                           offset: Point(x: 0, y: 0), tolerance: tolerance, ignoreAlpha: ignoreAlpha)
}

/// ずらして比べたときの印。**A の座標・A の大きさ**で返し、重なっていない所は 0。
public func differingPixels(
    a: [UInt8], sizeA: Size,
    b: [UInt8], sizeB: Size,
    bytesPerPixel: Int,
    offset: Point,
    tolerance: Int = 0,
    ignoreAlpha: Bool = false
) -> [UInt8] {
    var mask = [UInt8](repeating: 0, count: sizeA.width * sizeA.height)
    let o = overlapRect(sizeA: sizeA, sizeB: sizeB, offset: offset)
    guard o.x1 > o.x0, o.y1 > o.y0 else { return mask }
    let channels = (ignoreAlpha && bytesPerPixel == 4) ? 3 : bytesPerPixel
    for y in o.y0..<o.y1 {
        let rowA = y * sizeA.width * bytesPerPixel
        let rowB = (y - offset.y) * sizeB.width * bytesPerPixel
        for x in o.x0..<o.x1 {
            let i = rowA + x * bytesPerPixel
            let j = rowB + (x - offset.x) * bytesPerPixel
            for c in 0..<channels where abs(Int(a[i + c]) - Int(b[j + c])) > tolerance {
                mask[y * sizeA.width + x] = 1
                break
            }
        }
    }
    return mask
}

/// 全体の色の差。**B − A のチャンネルごとの平均（符号付き）。**
///
/// 「44% が違う」と出た写真が、実は全画素が同じ向きに +20 明るかった ── 圧縮のノイズでも
/// 細工でもなく、露出かトーンカーブの違い。数だけでは区別がつかないので、平均の向きを
/// 言う。寸法が違えば nil。RGBA なら最初の 3 本（アルファは色ではない）。
public struct ToneDifference: Equatable, Sendable {
    /// チャンネルごとの平均（B − A）。
    public let mean: [Double]
    /// 3 本の平均。正なら B のほうが明るい。
    public var overall: Double { mean.isEmpty ? 0 : mean.reduce(0, +) / Double(mean.count) }
}

public func toneDifference(
    a: [UInt8], sizeA: Size,
    b: [UInt8], sizeB: Size,
    bytesPerPixel: Int
) -> ToneDifference? {
    guard sizeA == sizeB else { return nil }
    let total = sizeA.width * sizeA.height
    guard total > 0 else { return nil }
    let channels = min(bytesPerPixel, 3)
    var sums = [Int](repeating: 0, count: channels)
    for p in 0..<total {
        let i = p * bytesPerPixel
        for c in 0..<channels { sums[c] += Int(b[i + c]) - Int(a[i + c]) }
    }
    return ToneDifference(mean: sums.map { Double($0) / Double(total) })
}
