import Foundation
import MrDiffCore

/// 行差分を色つきで組む。**表示だけ**で、判定は `MrDiffCore` が済ませてある。
///
/// 出力は `-` / `+` の unified diff 風。書き換わった行は `CharDiff` で**行内の
/// 変わった範囲だけ**を強調する ―― ログの `status=200 → 500` を探すのが本命なので、
/// 行を赤く塗るだけでは足りない。

struct Style {
    let on: Bool

    var reset: String { on ? "\u{1B}[0m" : "" }
    var dim: String { on ? "\u{1B}[2m" : "" }
    var red: String { on ? "\u{1B}[31m" : "" }
    var green: String { on ? "\u{1B}[32m" : "" }
    var cyan: String { on ? "\u{1B}[36m" : "" }
    /// 行内の変わった範囲。**色ではなく反転**にする ―― 赤の中の赤は読めない。
    var mark: String { on ? "\u{1B}[7m" : "" }
    var markOff: String { on ? "\u{1B}[27m" : "" }
}

/// 変わった範囲だけを反転させる。範囲は Character 単位（`CharDiff` の約束）。
private func highlight(_ line: String, _ ranges: [Range<Int>], _ s: Style) -> String {
    guard s.on, !ranges.isEmpty else { return line }
    let chars = Array(line)
    var out = ""
    var i = 0
    for r in ranges {
        let lo = min(r.lowerBound, chars.count), hi = min(r.upperBound, chars.count)
        if lo > i { out += String(chars[i..<lo]) }
        if hi > lo { out += s.mark + String(chars[lo..<hi]) + s.markOff }
        i = max(i, hi)
    }
    if i < chars.count { out += String(chars[i...]) }
    return out
}

/// 前後に見せる行数。unified diff と同じ 3。
let contextLines = 3

/// 差分を組み立てて返す。**`equal` は前後 `contextLines` 行だけ出す。**
func renderText(_ d: TextDiff, style s: Style) -> [String] {
    var out: [String] = []

    // **行番号は左右 2 列。**1 列だと、削除の行番号（左）と追加の行番号（右）が
    // たまたま同じ数になったとき、どちらの側の話か分からなくなる。
    func num(_ l: Int?, _ r: Int?) -> String {
        let ls = l.map { String(format: "%5d", $0 + 1) } ?? "     "
        let rs = r.map { String(format: "%5d", $0 + 1) } ?? "     "
        return ls + " " + rs
    }

    // 省略した行数を、飛ばしたことが分かる形で出す
    func skipped(_ n: Int) {
        guard n > 0 else { return }
        out.append("\(s.dim)\(String(repeating: " ", count: 11))   … \(n) unchanged\(s.reset)")
    }

    for (i, op) in d.ops.enumerated() {
        let isFirst = (i == 0), isLast = (i == d.ops.count - 1)
        switch op {
        case let .equal(l, r, count):
            // 前後だけ見せる。真ん中は行数だけ言う。
            let head = isFirst ? 0 : min(contextLines, count)
            let tail = isLast ? 0 : min(contextLines, count - head)
            for k in 0..<head {
                out.append("\(s.dim)\(num(l + k, r + k))   \(d.left[l + k])\(s.reset)")
            }
            skipped(count - head - tail)
            for k in (count - tail)..<count {
                out.append("\(s.dim)\(num(l + k, r + k))   \(d.left[l + k])\(s.reset)")
            }

        case let .delete(l, count):
            for k in 0..<count {
                out.append("\(s.red)\(num(l + k, nil)) - \(d.left[l + k])\(s.reset)")
            }

        case let .insert(r, count):
            for k in 0..<count {
                out.append("\(s.green)\(num(nil, r + k)) + \(d.right[r + k])\(s.reset)")
            }

        case let .replace(l, lc, r, rc):
            // 1 対 1 で並ぶぶんだけ行内差分を取る。数が合わない残りは行ごと。
            let pairs = min(lc, rc)
            for k in 0..<pairs {
                let a = d.left[l + k], b = d.right[r + k]
                let (lr, rr) = CharDiff.ranges(left: a, right: b)
                out.append("\(s.red)\(num(l + k, nil)) - \(highlight(a, lr, s))\(s.reset)")
                out.append("\(s.green)\(num(nil, r + k)) + \(highlight(b, rr, s))\(s.reset)")
            }
            for k in pairs..<lc {
                out.append("\(s.red)\(num(l + k, nil)) - \(d.left[l + k])\(s.reset)")
            }
            for k in pairs..<rc {
                out.append("\(s.green)\(num(nil, r + k)) + \(d.right[r + k])\(s.reset)")
            }
        }
    }
    return out
}
