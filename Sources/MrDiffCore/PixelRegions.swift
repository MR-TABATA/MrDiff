import Foundation

/// 違う画素の**塊**。「6.4% が違う」では何も分からない ── どこに、いくつの塊があるか。
///
/// MEMO-decisions §2 で設計だけして保留していたもの。GUI で「2 箇所目に飛べない」が
/// 実際に起きたので、判定側に置く（見せる側が自分でまとめ直さない）。
public struct PixelRegion: Equatable, Sendable {
    /// 外接矩形（左上の座標と大きさ）。
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// 塊に含まれる、違う画素の数。
    public let count: Int

    public init(x: Int, y: Int, width: Int, height: Int, count: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.count = count
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    /// 重心ではなく矩形の中心。飛ぶ先として十分。
    public var center: Point { Point(x: x + width / 2, y: y + height / 2) }
}

/// 塊にまとめる。
///
/// 1. 8 近傍で繋がった画素を 1 つの塊にする（パラメータ不要）
/// 2. 塊どうしの矩形の隙間が `near` 以下なら 1 つにまとめる。**`near` は画像の短辺に比例**
///    （`max(2, 短辺 ÷ 100)`: 32x32 → 2px、1280x800 → 8px、4K → 22px）
///
/// 数は絶対の事実ではなく `near` 次第なので、**使った距離は隠さない**（呼ぶ側が出力に書く）。
/// 結果は左上から読む順（y、次に x）。
public func differenceRegions(mask: [UInt8], width: Int, height: Int, near: Int? = nil) -> [PixelRegion] {
    guard width > 0, height > 0, mask.count == width * height else { return [] }
    let near = near ?? max(2, min(width, height) / 100)

    // 1. 連結成分。ラベルは 0 = 未訪問。塊ごとに矩形と数を持つ。
    var labels = [Int32](repeating: 0, count: mask.count)
    var boxes: [PixelRegion] = []
    var stack: [Int] = []
    for start in 0..<mask.count where mask[start] != 0 && labels[start] == 0 {
        let label = Int32(boxes.count + 1)
        var minX = width, minY = height, maxX = -1, maxY = -1, count = 0
        labels[start] = label
        stack.append(start)
        while let p = stack.popLast() {
            let px = p % width, py = p / width
            count += 1
            if px < minX { minX = px }
            if px > maxX { maxX = px }
            if py < minY { minY = py }
            if py > maxY { maxY = py }
            for dy in -1...1 {
                let ny = py + dy
                guard ny >= 0, ny < height else { continue }
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = px + dx
                    guard nx >= 0, nx < width else { continue }
                    let q = ny * width + nx
                    if mask[q] != 0 && labels[q] == 0 {
                        labels[q] = label
                        stack.append(q)
                    }
                }
            }
        }
        boxes.append(PixelRegion(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1, count: count))
    }

    // 2. 近い矩形をまとめる。まとめて大きくなった矩形がさらに別と近づくことがあるので、
    //    変化が無くなるまで回す。塊の数は多くても数千なので、素朴でよい。
    var merged = boxes
    var changed = true
    while changed {
        changed = false
        var out: [PixelRegion] = []
        for r in merged {
            if let i = out.firstIndex(where: { gap($0, r) <= near }) {
                out[i] = union(out[i], r)
                changed = true
            } else {
                out.append(r)
            }
        }
        merged = out
    }
    return merged.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
}

/// 2 つの矩形の隙間（重なっていれば 0）。縦横の隙間の大きいほう。
private func gap(_ a: PixelRegion, _ b: PixelRegion) -> Int {
    let dx = max(0, max(a.x, b.x) - min(a.maxX, b.maxX))
    let dy = max(0, max(a.y, b.y) - min(a.maxY, b.maxY))
    return max(dx, dy)
}

private func union(_ a: PixelRegion, _ b: PixelRegion) -> PixelRegion {
    let x = min(a.x, b.x), y = min(a.y, b.y)
    return PixelRegion(x: x, y: y, width: max(a.maxX, b.maxX) - x, height: max(a.maxY, b.maxY) - y,
                       count: a.count + b.count)
}
