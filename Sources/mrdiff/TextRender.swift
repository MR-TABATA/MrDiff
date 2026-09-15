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

/// 標準出力へ**流しながら**書く。
///
/// 最初の実装は組み上げた行を `[String]` で返していた。全行が違う 100 万行 × 2 で
/// 出力が 200 万行になり、それを全部メモリに持って **734MB・7.7 秒**（判定自体は
/// 0.14 秒で済んでいた）。**表示のほうが、比較の 50 倍かかっていた。**
///
/// 1 行ずつ `print` するのも遅い（毎回ロックと flush が走る）。1MB 溜めて出す。
struct Out {
    private var buf = Data()
    private let limit = 1 << 20
    /// 書き込み先。ページャを立てたときはその入口、それ以外は標準出力。
    /// **`FILE *` に揃える** ―― `print` と同じ口なので、順番が入れ替わらない。
    private var sink: UnsafeMutablePointer<FILE>
    /// 相手が先に消えたら、書くのをやめる（ページャを q で抜けた場合）
    private var closed = false
    /// 一度でも書けたか。**まだ 1 バイトも書けていないうちの失敗は、
    /// 「読み手が抜けた」ではなく「ページャが立ち上がらなかった」。**
    private var wroteSomething = false

    init(to sink: UnsafeMutablePointer<FILE> = stdout) {
        self.sink = sink
        buf.reserveCapacity(limit + 4096)
    }

    mutating func line(_ s: String) {
        guard !closed else { return }
        buf.append(contentsOf: s.utf8)
        buf.append(0x0A)
        if buf.count >= limit { flush() }
    }

    mutating func flush() {
        guard !closed, !buf.isEmpty else { return }
        if write(to: sink) {
            wroteSomething = true
        } else if !wroteSomething, sink != stdout {
            // **1 バイトも書けていないなら、ページャが立ち上がっていない。**
            // MRDIFF_PAGER を打ち間違えただけで差分が消えるのは、割に合わない。
            sink = stdout
            wroteSomething = write(to: sink)
            if !wroteSomething { closed = true }
        } else {
            // 読み手が q で抜けた。**落ちるのではなく、そこでやめる**（git と同じ）。
            closed = true
        }
        buf.removeAll(keepingCapacity: true)
    }

    private func write(to f: UnsafeMutablePointer<FILE>) -> Bool {
        buf.withUnsafeBytes { raw -> Bool in
            guard let p = raw.baseAddress, raw.count > 0 else { return true }
            return fwrite(p, 1, raw.count, f) == raw.count
        }
    }
}

/// JSON / YAML の構造差分を並べる。**行番号の代わりにパス**（`user.name` / `items[2]`）、
/// 行の中身の代わりに値。行 diff の `-` / `+` と同じ記号を使い、変わった場所（削除・追加の
/// どちらでもない）だけ `~` を足す ―― 3 つ目の状態なので、既存の赤 / 緑とは別の色
/// （未使用だった cyan）を当てる。値は 1 行に収まる長さへ丸める（`shortDescription`）――
/// パスだけでは「どこが」までしか言えず、「一覧だけでは何が何だか分からない」の穴になる。
func renderStructured(_ d: StructuredDiff, style s: Style, into out: inout Out) {
    for c in d.changes {
        let label = c.path.isEmpty ? t("structured.root") : c.path
        switch c.kind {
        case .removed:
            let value = c.before.map { shortDescription($0) } ?? ""
            out.line("\(s.red) - \(label): \(value)\(s.reset)")
        case .added:
            let value = c.after.map { shortDescription($0) } ?? ""
            out.line("\(s.green) + \(label): \(value)\(s.reset)")
        case .changed:
            let before = c.before.map { shortDescription($0) } ?? "?"
            let after = c.after.map { shortDescription($0) } ?? "?"
            out.line("\(s.cyan) ~ \(label): \(before) → \(after)\(s.reset)")
        }
    }
}

/// 前後に見せる行数。unified diff と同じ 3。
let contextLines = 3

/// 行内差分を取る上限。**これを超える変更行があれば、行内は見ない。**
///
/// 1 行ごとに LCS を回すので、変更行が数十万あると表示だけで数秒かかる。
/// そもそも 200 万行の差分を人が読むことはなく、**読めない出力のために待たせるほうが害。**
let charDiffLineBudget = 5_000

/// 差分を書き出す。**`equal` は前後 `contextLines` 行だけ出す。**
func renderText(_ d: TextDiff, style s: Style, into out: inout Out) {
    // 変更行が多すぎるときは行内差分を諦める（`charDiffLineBudget`）
    let inlineOK = d.changed <= charDiffLineBudget

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
        out.line("\(s.dim)\(String(repeating: " ", count: 11))   … \(n) unchanged\(s.reset)")
    }

    for (i, op) in d.ops.enumerated() {
        let isFirst = (i == 0), isLast = (i == d.ops.count - 1)
        switch op {
        case let .equal(l, r, count):
            // 前後だけ見せる。真ん中は行数だけ言う。
            let head = isFirst ? 0 : min(contextLines, count)
            let tail = isLast ? 0 : min(contextLines, count - head)
            for k in 0..<head {
                out.line("\(s.dim)\(num(l + k, r + k))   \(d.left.line(l + k))\(s.reset)")
            }
            skipped(count - head - tail)
            for k in (count - tail)..<count {
                out.line("\(s.dim)\(num(l + k, r + k))   \(d.left.line(l + k))\(s.reset)")
            }

        case let .delete(l, count):
            for k in 0..<count {
                out.line("\(s.red)\(num(l + k, nil)) - \(d.left.line(l + k))\(s.reset)")
            }

        case let .insert(r, count):
            for k in 0..<count {
                out.line("\(s.green)\(num(nil, r + k)) + \(d.right.line(r + k))\(s.reset)")
            }

        case let .replace(l, lc, r, rc):
            // 1 対 1 で並ぶぶんだけ行内差分を取る。数が合わない残りは行ごと。
            let pairs = min(lc, rc)
            for k in 0..<pairs {
                let a = d.left.line(l + k), b = d.right.line(r + k)
                let (lr, rr) = inlineOK ? CharDiff.ranges(left: a, right: b) : ([], [])
                out.line("\(s.red)\(num(l + k, nil)) - \(highlight(a, lr, s))\(s.reset)")
                out.line("\(s.green)\(num(nil, r + k)) + \(highlight(b, rr, s))\(s.reset)")
            }
            for k in pairs..<lc {
                out.line("\(s.red)\(num(l + k, nil)) - \(d.left.line(l + k))\(s.reset)")
            }
            for k in pairs..<rc {
                out.line("\(s.green)\(num(nil, r + k)) + \(d.right.line(r + k))\(s.reset)")
            }
        }
    }
}
