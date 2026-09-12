import Foundation

/// `--json` の出力。**形はここで決まり、公開した瞬間から変えられない。**
///
/// main.swift が文字列を手で連結していた版は、`"` しかエスケープしておらず、
/// `\` や改行を含むパスで壊れた JSON を出した。ここでは辞書を組んで
/// `JSONSerialization` に任せる。キーはソートして出す（出力が毎回同じ並びになり、
/// テストと人の目の両方で比べやすい）。
///
/// 全部の出力に共通のキーが 2 つ:
///   - `kind`   … 何として比べたか（`text` / `image` / `binary` / `site` / `tree`）。
///                中身で振り分けているからこそ、何に振り分けたかを返す（`.bin` と名付けた PNG）。
///   - `result` … `identical` / `differ`、画像だけ `size_mismatch`、site だけ `error`
///                （違いは無いが確認できなかったものがある）。
///
/// **緩めて比べたら、JSON にもそう書く。** `tolerance` / `ignore_alpha` は
/// 緩めたときだけ付く。付いていなければ厳密比較、で読める。人向けの出力が
/// 「compared with ±2 per channel」を必ず添えるのと同じ約束。
///
/// **訳さない。** 機械が読むものなので、`MRDIFF_LANG` に関わらず同じ文字列。
public enum JSONOutput {

    /// URL が飛ばされたとき。`from` は打ったもの、`to` は中身を取った先。
    public struct Redirect: Equatable {
        public let from: String
        public let to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    // MARK: - 種類ごと

    public static func text(_ d: TextDiff, redirects: [Redirect] = []) -> [String: Any] {
        var o: [String: Any] = ["kind": "text"]
        if d.isIdentical {
            o["result"] = "identical"
        } else {
            o["result"] = "differ"
            o["changed"] = d.changed   // replace ハンクの max(左, 右)。README に定義を書いてある
            o["added"] = d.added
            o["removed"] = d.removed
        }
        addRedirects(&o, redirects)
        return o
    }

    public static func image(_ r: ImageComparison, tolerance: Int, ignoreAlpha: Bool,
                             tone: ToneDifference? = nil, redirects: [Redirect] = []) -> [String: Any] {
        var o: [String: Any] = ["kind": "image"]
        // 全体の色の差（B − A の平均、チャンネルごと）。寸法が違えば無い。
        if let tone { o["tone_shift"] = tone.mean.map { NSDecimalNumber(string: String(format: "%.1f", $0)) } }
        switch r {
        case .identical:
            o["result"] = "identical"
        case .sizeMismatch(let a, let b):
            o["result"] = "size_mismatch"
            o["a"] = ["width": a.width, "height": a.height]
            o["b"] = ["width": b.width, "height": b.height]
        case .differ(let d):
            o["result"] = "differ"
            o["changed"] = d.changed
            o["total"] = d.total
            // Double をそのまま渡すと 0.03 が 0.029999999999999999 と出る（17 桁で書く）。
            // Swift の最短表現（"0.03"）を Decimal に読ませて、その字面で書かせる。
            o["fraction"] = NSDecimalNumber(string: String(d.fraction))
            o["first"] = ["x": d.first.x, "y": d.first.y]
            o["max_gap"] = d.maxGap   // --tolerance=<これ> なら同じになる
        }
        if tolerance > 0 { o["tolerance"] = tolerance }
        if ignoreAlpha { o["ignore_alpha"] = true }
        addRedirects(&o, redirects)
        return o
    }

    public static func binary(_ d: BinaryDiff.Result, redirects: [Redirect] = []) -> [String: Any] {
        var o: [String: Any] = ["kind": "binary"]
        if d.isIdentical {
            o["result"] = "identical"
        } else {
            o["result"] = "differ"
            o["regions"] = d.regions.count
            o["differing_bytes"] = d.differingBytes
            // 画像の `first:{x,y}` と形を揃える。無い（長さだけ違う）なら null
            o["first"] = d.first.map { ["offset": $0.offset] as Any } ?? NSNull()
            o["size_a"] = d.sizeA
            o["size_b"] = d.sizeB
        }
        addRedirects(&o, redirects)
        return o
    }

    /// `--site`。`result` は、違いがあれば `differ`、違いは無いが確認できなかったものが
    /// あれば `error`、全部同じなら `identical`。**error を identical に混ぜない**のは
    /// 人向けの `in_sync` と同じ線。
    public static func site(_ r: SiteDiff) -> [String: Any] {
        let differs = !r.changed.isEmpty || !r.missing.isEmpty
        let result = r.allInSync ? "identical" : (differs ? "differ" : "error")
        let rows: [[String: Any]] = r.rows.map { row in
            let st: String
            switch row.status {
            case .identical: st = "identical"
            case .changed:   st = "changed"
            case .missing:   st = "missing"
            case .error:     st = "error"
            }
            return ["path": row.entry.localPath, "status": st]
        }
        return [
            "kind": "site",
            "result": result,
            "in_sync": r.allInSync,
            "files": r.rows.count,
            "changed": r.changed.count,
            "missing": r.missing.count,
            "errors": r.errored.count,
            "rows": rows,
        ]
    }

    /// `--ssh`（ディレクトリ両方向）。
    public static func tree(_ d: TreeDiff) -> [String: Any] {
        let rows: [[String: Any]] = d.rows.map { row in
            let st: String
            switch row.status {
            case .identical: st = "identical"
            case .changed:   st = "changed"
            case .onlyLeft:  st = "only_local"
            case .onlyRight: st = "only_remote"
            }
            return ["path": row.path, "status": st]
        }
        return [
            "kind": "tree",
            "result": d.allIdentical ? "identical" : "differ",
            "in_sync": d.allIdentical,
            "files": d.rows.count,
            "changed": d.changed.count,
            "only_local": d.onlyLeft.count,
            "only_remote": d.onlyRight.count,
            "rows": rows,
        ]
    }

    // MARK: - 直列化

    /// 1 行の JSON。キーはソート、`/` はエスケープしない（URL が読める）。
    public static func encode(_ o: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func addRedirects(_ o: inout [String: Any], _ rs: [Redirect]) {
        guard !rs.isEmpty else { return }
        o["redirected"] = rs.map { ["from": $0.from, "to": $0.to] }
    }
}
