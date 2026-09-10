import Foundation

// **MrEditor からの意図的な写し。同期しない。**
//
// 元: ~/Git/MrEditor/Sources/MrEditorCore/Core/LineDiff.swift（2026-09-10 時点）
//
// 共有（public 化・別パッケージ化）はしない。共有が得なのは**両方が変わり続けるとき**
// だけで、MrEditor 側の diff は完成している。片方が止まっているなら、共有は結合を
// 増やすだけになる。MIT・作者も同じなので写して問題ない。
//
// **直すときは、こちらだけ直す。**向こうへ持ち帰らない（持ち帰ると、公開 API が
// 永久に増える）。半年後に「片方だけ直っている、どっちが正しい？」にならないよう、
// この注記を消さないこと。


/// 行のハッシュ。**128 ビット**にしてある。
///
/// 64 ビットだと 8,600 万行で誕生日衝突が 10^-4 オーダーに乗る。diff で衝突が起きると
/// 「違う行を同じと言う」＝**黙って差分を見落とす**ことになり、閲覧側の「落とさない」より
/// たちが悪い。16 バイト/行のコストを払って潰す（10GB・86,420,337 行で 1.4GB）。
public struct LineHash: Hashable, Sendable {
    public let a: UInt64
    public let b: UInt64
    public init(a: UInt64, b: UInt64) {
        self.a = a
        self.b = b
    }
}

/// diff の 1 手。行の範囲で表す。
public enum DiffOp: Equatable, Sendable {
    /// 両方に同じ行が count 行続く。
    case equal(left: Int, right: Int, count: Int)
    /// 左にしかない（削除）。
    case delete(left: Int, count: Int)
    /// 右にしかない（追加）。
    case insert(right: Int, count: Int)
    /// 置き換え（左の一塊が右の一塊になった）。行内差分はこのブロックの中で取る。
    case replace(left: Int, leftCount: Int, right: Int, rightCount: Int)
}

/// 行単位の diff。
///
/// **patience diff**（両側で 1 回しか出てこない行＝アンカーを見つけ、その間を再帰）を採る。
/// 巨大なログで Myers を素直に回すと O(ND) が破裂するが、patience は
///   - 共通の先頭・末尾を落とす（ログは大抵ここで大半が消える）
///   - アンカー間の小さな区間だけを詳しく見る
/// ので、メモリも時間も行数に対してほぼ線形に収まる。
///
/// アンカーが 1 つも無い区間（全行が重複だらけ、等）は、区間が小さければ Myers、
/// 大きければ丸ごと replace として畳む（**嘘をつかず、諦めたことが分かる形**にする）。
public enum LineDiff {

    /// アンカーが無い区間に Myers を回してよい上限（左右の行数の積）。
    /// これを超えたら 1 個の replace に畳む。
    static let myersCellBudget = 4_000_000

    public static func compute(_ left: [LineHash], _ right: [LineHash]) -> [DiffOp] {
        var ops: [DiffOp] = []
        diff(left, right, 0..<left.count, 0..<right.count, into: &ops)
        return coalesce(ops)
    }

    // MARK: - 本体

    private static func diff(_ l: [LineHash], _ r: [LineHash],
                            _ lr: Range<Int>, _ rr: Range<Int>,
                            into ops: inout [DiffOp]) {
        var lo = lr, ro = rr

        // 共通の先頭
        var prefix = 0
        while lo.lowerBound + prefix < lo.upperBound,
              ro.lowerBound + prefix < ro.upperBound,
              l[lo.lowerBound + prefix] == r[ro.lowerBound + prefix] {
            prefix += 1
        }
        if prefix > 0 {
            ops.append(.equal(left: lo.lowerBound, right: ro.lowerBound, count: prefix))
            lo = (lo.lowerBound + prefix)..<lo.upperBound
            ro = (ro.lowerBound + prefix)..<ro.upperBound
        }

        // 共通の末尾
        var suffix = 0
        while lo.upperBound - suffix - 1 >= lo.lowerBound,
              ro.upperBound - suffix - 1 >= ro.lowerBound,
              l[lo.upperBound - suffix - 1] == r[ro.upperBound - suffix - 1] {
            suffix += 1
        }
        let lMid = lo.lowerBound..<(lo.upperBound - suffix)
        let rMid = ro.lowerBound..<(ro.upperBound - suffix)

        emitMiddle(l, r, lMid, rMid, into: &ops)

        if suffix > 0 {
            ops.append(.equal(left: lo.upperBound - suffix, right: ro.upperBound - suffix, count: suffix))
        }
    }

    private static func emitMiddle(_ l: [LineHash], _ r: [LineHash],
                                   _ lr: Range<Int>, _ rr: Range<Int>,
                                   into ops: inout [DiffOp]) {
        if lr.isEmpty && rr.isEmpty { return }
        if lr.isEmpty { ops.append(.insert(right: rr.lowerBound, count: rr.count)); return }
        if rr.isEmpty { ops.append(.delete(left: lr.lowerBound, count: lr.count)); return }

        // **表に載せる前に、揃ったまま歩けるところは歩く。**
        //
        // 先頭と末尾の共通部分を落としても、変更が離れて点在していれば「真ん中」は
        // ほぼ全体のまま残る（100 万行で 3 行違うだけの実測で、真ん中が 98 万行）。
        // そこを丸ごとアンカー表に載せると、3 行のために 243MB と 0.16 秒を払う。
        //
        // 大半が一致している 2 本では、真ん中は**一致の連なりと、点在する小さなずれ**
        // でできている。歩けるところを歩き、ずれたら狭い窓で合流点を探す。
        // 見つからなければ、残りを今までどおりアンカーへ渡す（**諦めたことが分かる形**）。
        var li = lr.lowerBound, ri = rr.lowerBound
        var walked = false
        while li < lr.upperBound && ri < rr.upperBound {
            // 揃っているあいだ進む
            var run = 0
            while li + run < lr.upperBound && ri + run < rr.upperBound
                    && l[li + run] == r[ri + run] { run += 1 }
            if run > 0 {
                ops.append(.equal(left: li, right: ri, count: run))
                li += run
                ri += run
                walked = true
                continue
            }
            // ずれた。狭い窓で合流点を探す
            guard let (da, db) = resync(l, r, li..<lr.upperBound, ri..<rr.upperBound) else { break }
            if da > 0 && db > 0 {
                ops.append(.replace(left: li, leftCount: da, right: ri, rightCount: db))
            } else if da > 0 {
                ops.append(.delete(left: li, count: da))
            } else {
                ops.append(.insert(right: ri, count: db))
            }
            li += da
            ri += db
            walked = true
        }
        if li >= lr.upperBound || ri >= rr.upperBound {
            // 片側が尽きた。残りはまるごと足す / 消す
            if li < lr.upperBound { ops.append(.delete(left: li, count: lr.upperBound - li)) }
            if ri < rr.upperBound { ops.append(.insert(right: ri, count: rr.upperBound - ri)) }
            return
        }
        if walked {
            // 歩けたところまでは片づいた。残りを、この関数の続きへ回す
            emitMiddle(l, r, li..<lr.upperBound, ri..<rr.upperBound, into: &ops)
            return
        }

        // アンカー = 左右それぞれで 1 回だけ出てくる、共通の行。
        guard let anchors = uniqueAnchors(l, r, lr, rr), !anchors.isEmpty else {
            // アンカー無し。小さければ Myers、大きければ諦めて replace。
            if lr.count * rr.count <= myersCellBudget {
                myers(l, r, lr, rr, into: &ops)
            } else {
                ops.append(.replace(left: lr.lowerBound, leftCount: lr.count,
                                    right: rr.lowerBound, rightCount: rr.count))
            }
            return
        }

        // アンカー列（左昇順・右も昇順になるよう LIS で選抜済み）で区切って再帰。
        var lPos = lr.lowerBound
        var rPos = rr.lowerBound
        for (li, ri) in anchors {
            diff(l, r, lPos..<li, rPos..<ri, into: &ops)
            ops.append(.equal(left: li, right: ri, count: 1))
            lPos = li + 1
            rPos = ri + 1
        }
        diff(l, r, lPos..<lr.upperBound, rPos..<rr.upperBound, into: &ops)
    }

    /// ずれた地点から、**狭い窓の中だけ**で合流点を探す。
    ///
    /// 返すのは「左を何行、右を何行飛ばせば揃うか」。窓の中に無ければ nil で、
    /// そのときはアンカー探索へ回す ―― **窓を広げて粘らない。**粘ると、
    /// 大きく入れ替わったファイルで窓の中を延々と探すことになる。
    ///
    /// `confirm` 行そろって一致するまで合流と認めない。1 行だけの偶然の一致で
    /// 合流したことにすると、そこから先が全部ずれて出る。
    static let resyncWindow = 64
    static let resyncConfirm = 3

    private static func resync(_ l: [LineHash], _ r: [LineHash],
                               _ lr: Range<Int>, _ rr: Range<Int>) -> (Int, Int)? {
        func matches(_ a: Int, _ b: Int) -> Bool {
            var k = 0
            while k < resyncConfirm {
                let li = a + k, ri = b + k
                // 端に着いたら、そこまで揃っていれば合流と認める
                if li >= lr.upperBound || ri >= rr.upperBound { return k > 0 }
                if l[li] != r[ri] { return false }
                k += 1
            }
            return true
        }
        // 飛ばす行数の合計が小さい順に見る（小さいずれを優先する）
        for total in 1...(resyncWindow * 2) {
            for da in max(0, total - resyncWindow)...min(total, resyncWindow) {
                let db = total - da
                let a = lr.lowerBound + da, b = rr.lowerBound + db
                if a > lr.upperBound || b > rr.upperBound { continue }
                if matches(a, b) { return (da, db) }
            }
        }
        return nil
    }

    /// 左右それぞれの区間で出現回数 1、かつ両方に在る行を拾い、
    /// 右のインデックスが増加する最長列（LIS）だけ残す＝交差しないアンカー列。
    private static func uniqueAnchors(_ l: [LineHash], _ r: [LineHash],
                                      _ lr: Range<Int>, _ rr: Range<Int>) -> [(Int, Int)]? {
        // **Swift の Dictionary は使わない。**ここは区間の行数ぶんだけ引きが走るので、
        // 1 件あたりの重さがそのまま時間とメモリになる。100 万行で辞書だけが
        // 250MB 前後を占めていた。鍵は既に 128 ビットのハッシュなので、
        // 再ハッシュの要らない開番地表で足りる（`AnchorTable`）。
        var lSeen = AnchorTable(capacity: lr.count)
        for i in lr { lSeen.add(l[i], at: i) }
        var rSeen = AnchorTable(capacity: rr.count)
        for i in rr { rSeen.add(r[i], at: i) }

        var pairs: [(Int, Int)] = []
        lSeen.forEachUnique { h, li in
            if let ri = rSeen.uniqueIndex(of: h) { pairs.append((li, ri)) }
        }
        if pairs.isEmpty { return nil }
        pairs.sort { $0.0 < $1.0 }

        // 右インデックスの LIS（狭義単調増加）。
        var tails: [Int] = []          // tails[k] = 長さ k+1 の列の末尾の「右index」
        var tailIdx: [Int] = []        // その pairs 上の位置
        var prev = [Int](repeating: -1, count: pairs.count)
        for (i, p) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if tails[mid] < p.1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[i] = tailIdx[lo - 1] }
            if lo == tails.count { tails.append(p.1); tailIdx.append(i) }
            else { tails[lo] = p.1; tailIdx[lo] = i }
        }
        var out: [(Int, Int)] = []
        var k = tails.isEmpty ? -1 : tailIdx[tails.count - 1]
        while k >= 0 { out.append(pairs[k]); k = prev[k] }
        out.reverse()
        return out
    }

    /// 小さい区間だけに使う Myers（O(ND)）。区間の外へは出ない。
    private static func myers(_ l: [LineHash], _ r: [LineHash],
                              _ lr: Range<Int>, _ rr: Range<Int>,
                              into ops: inout [DiffOp]) {
        let n = lr.count, m = rr.count
        // 素朴な LCS（DP）。myersCellBudget で面積を抑えてあるので現実的。
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = (l[lr.lowerBound + i] == r[rr.lowerBound + j])
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < n && j < m {
            if l[lr.lowerBound + i] == r[rr.lowerBound + j] {
                ops.append(.equal(left: lr.lowerBound + i, right: rr.lowerBound + j, count: 1))
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.delete(left: lr.lowerBound + i, count: 1)); i += 1
            } else {
                ops.append(.insert(right: rr.lowerBound + j, count: 1)); j += 1
            }
        }
        if i < n { ops.append(.delete(left: lr.lowerBound + i, count: n - i)) }
        if j < m { ops.append(.insert(right: rr.lowerBound + j, count: m - j)) }
    }

    // MARK: - 整形

    /// 連続する同種の手をまとめ、隣り合う delete+insert は replace に畳む
    /// （「消して足した」より「書き換わった」と見せたほうが読める。行内差分もここに効く）。
    public static func coalesce(_ ops: [DiffOp]) -> [DiffOp] {
        var merged: [DiffOp] = []
        for op in ops {
            guard let last = merged.last else { merged.append(op); continue }
            switch (last, op) {
            case let (.equal(l1, r1, c1), .equal(l2, r2, c2)) where l1 + c1 == l2 && r1 + c1 == r2:
                merged[merged.count - 1] = .equal(left: l1, right: r1, count: c1 + c2)
            case let (.delete(l1, c1), .delete(l2, c2)) where l1 + c1 == l2:
                merged[merged.count - 1] = .delete(left: l1, count: c1 + c2)
            case let (.insert(r1, c1), .insert(r2, c2)) where r1 + c1 == r2:
                merged[merged.count - 1] = .insert(right: r1, count: c1 + c2)
            default:
                merged.append(op)
            }
        }

        var out: [DiffOp] = []
        var k = 0
        while k < merged.count {
            if case let .delete(l, lc) = merged[k], k + 1 < merged.count,
               case let .insert(r, rc) = merged[k + 1] {
                out.append(.replace(left: l, leftCount: lc, right: r, rightCount: rc))
                k += 2
            } else if case let .insert(r, rc) = merged[k], k + 1 < merged.count,
                      case let .delete(l, lc) = merged[k + 1] {
                out.append(.replace(left: l, leftCount: lc, right: r, rightCount: rc))
                k += 2
            } else {
                out.append(merged[k])
                k += 1
            }
        }
        return out
    }
}

/// アンカー探索用の開番地表。**`LineDiff` の中だけで使う。**
///
/// Swift の `Dictionary` は 1 件あたりの確保と再ハッシュが効いてきて、
/// 100 万行の区間で 250MB 前後・0.2 秒前後を持っていっていた。鍵の `LineHash` は
/// 既に 128 ビットのハッシュなので、**その下位ビットをそのまま席に使えばよい。**
///
/// 中身は「鍵・最後に見た位置・出現回数」を平らな配列に置くだけ。伸長はしない
/// （必要な席数が最初から分かっている）。
struct AnchorTable {
    private struct Slot {
        var key = LineHash(a: 0, b: 0)
        var index: Int = -1
        var count: Int32 = 0
    }
    private var slots: [Slot]
    private let mask: Int

    /// 席は要素数の 2 倍以上の 2 冪。**半分以上を空けておく**と、線形探索が伸びない。
    init(capacity: Int) {
        var size = 16
        while size < capacity * 2 { size <<= 1 }
        slots = [Slot](repeating: Slot(), count: size)
        mask = size - 1
    }

    @inline(__always)
    private func home(_ key: LineHash) -> Int {
        Int(truncatingIfNeeded: key.a) & mask
    }

    mutating func add(_ key: LineHash, at index: Int) {
        var i = home(key)
        while true {
            if slots[i].count == 0 {
                slots[i] = Slot(key: key, index: index, count: 1)
                return
            }
            if slots[i].key == key {
                // 2 回目以降。**位置は最後のものを残す**（元の実装と同じ）。
                slots[i].index = index
                if slots[i].count < Int32.max { slots[i].count += 1 }
                return
            }
            i = (i + 1) & mask
        }
    }

    /// その区間で 1 回だけ出てきた鍵の位置。2 回以上なら nil。
    func uniqueIndex(of key: LineHash) -> Int? {
        var i = home(key)
        while slots[i].count != 0 {
            if slots[i].key == key { return slots[i].count == 1 ? slots[i].index : nil }
            i = (i + 1) & mask
        }
        return nil
    }

    /// 1 回だけ出てきたものを順に渡す。
    func forEachUnique(_ body: (LineHash, Int) -> Void) {
        for s in slots where s.count == 1 { body(s.key, s.index) }
    }
}
