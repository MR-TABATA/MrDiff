import Foundation

/// テキストの比較。**行に切って、ハッシュにして、`LineDiff` へ渡す**までを持つ。
///
/// 差分そのものの計算は `LineDiff`（MrEditor からの写し）が持っていて、ここはその前後
/// ―― 読み込み・行分割・ハッシュ・数え上げ ―― だけを受け持つ。表示は CLI 側。
///
/// **行を `String` にしない。**最初の実装は全行を `[String]` に起こしていて、
/// 100 万行（75MB×2）で 988MB 食った ―― 入力の 6.5 倍。この比のままだと 10GB では
/// 起動すらしない。バイト範囲だけ覚え、`String` にするのは**表示する行だけ**にする。

// MARK: - どの種類のファイルか

/// 比較の入口で決める種類。**中身で決める**（拡張子は見ない）。
public enum FileKind: Equatable, Sendable {
    /// UTF-8 として読めて、NUL を含まない
    case text
    /// それ以外（画像・バイナリ）
    case other
}

/// 中身を見て種類を決める。
///
/// **NUL を含むものはテキストとして扱わない。**`diff` や `grep` と同じ線で、
/// UTF-8 として偶然読めてしまう UTF-16 のファイルなどをここで落とせる。
///
/// 大きなファイルで全部を舐めないよう、**先頭 `probe` バイトだけ**を見る。
public func detectKind(_ data: Data, probe: Int = 8192) -> FileKind {
    let head = data.prefix(probe)
    if head.contains(0) { return .other }
    // 途中で切れた UTF-8 の多バイト文字を「壊れている」と誤判定しないよう、
    // 末尾の数バイトは落として判定する。
    let trimmed = head.count < data.count ? head.dropLast(4) : head
    return String(data: Data(trimmed), encoding: .utf8) != nil ? .text : .other
}

// MARK: - 行の並び

/// 片側のテキスト。**中身はバイトのまま持ち、行はその範囲で指す。**
public struct TextSource {
    /// ファイルの中身。`mappedIfSafe` で開けば、ここは常駐メモリに乗らない。
    public let data: Data
    /// 各行の**中身**のバイト範囲（改行と、その手前の CR は含まない）。
    public let lines: [Range<Int>]
    /// 各行のハッシュ。`LineDiff` へ渡すのはこれ。
    public let hashes: [LineHash]

    public var count: Int { lines.count }

    /// 表示する行だけ `String` に起こす。
    public func line(_ i: Int) -> String {
        let r = lines[i]
        let base = data.startIndex
        return String(decoding: data[(base + r.lowerBound)..<(base + r.upperBound)],
                      as: UTF8.self)
    }

    /// バイト列から組み立てる。**1 回の走査で、行の切り出しとハッシュを同時にやる。**
    ///
    /// `ignoreWhitespace` はハッシュ（＝行の同一判定）だけに効く。**表示（`line(_:)`）は
    /// 常に元のバイトのまま** ── 空白を無視した比較でも、画面には削らず出す。
    public init(data: Data, ignoreWhitespace: Bool = false) {
        var ranges: [Range<Int>] = []
        var hs: [LineHash] = []
        // 1 行 40 バイト前後を見込んで先に確保する（伸長のたびの再確保を減らす）
        let guess = max(16, data.count / 40)
        ranges.reserveCapacity(guess)
        hs.reserveCapacity(guess)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var start = 0
            var i = 0
            while i < n {
                if base[i] == 0x0A {                       // \n
                    var end = i
                    if end > start && base[end - 1] == 0x0D { end -= 1 }   // \r\n
                    ranges.append(start..<end)
                    hs.append(ignoreWhitespace ? hashBytesIgnoringWhitespace(base + start, end - start)
                                               : hashBytes(base + start, end - start))
                    start = i + 1
                }
                i += 1
            }
            // 末尾に改行が無ければ、残りが最後の 1 行
            if start < n {
                var end = n
                if end > start && base[end - 1] == 0x0D { end -= 1 }
                ranges.append(start..<end)
                hs.append(ignoreWhitespace ? hashBytesIgnoringWhitespace(base + start, end - start)
                                           : hashBytes(base + start, end - start))
            }
        }

        self.data = data
        self.lines = ranges
        self.hashes = hs
    }

    /// 文字列から。テスト・小さな入力用。
    public init(text: String, ignoreWhitespace: Bool = false) {
        self.init(data: Data(text.utf8), ignoreWhitespace: ignoreWhitespace)
    }

    /// ファイルから。**`mappedIfSafe` で開く** ―― 中身を常駐メモリへ写さない。
    public static func load(_ url: URL, ignoreWhitespace: Bool = false) throws -> TextSource {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ImageLoadError.cannotOpen(url)
        }
        return TextSource(data: data, ignoreWhitespace: ignoreWhitespace)
    }
}

/// 行のハッシュ。**FNV-1a を 2 通り回して 128 ビットにする。**
///
/// 64 ビットだと大きなファイルで誕生日衝突が現実的な確率に乗る。diff の衝突は
/// 「違う行を同じと言う」＝**黙って差分を見落とす**ことなので、そこは払う
/// （`LineDiff.LineHash` の注記と同じ理由）。
@inline(__always)
func hashBytes(_ p: UnsafePointer<UInt8>, _ count: Int) -> LineHash {
    var a: UInt64 = 0xcbf2_9ce4_8422_2325       // FNV offset basis
    var b: UInt64 = 0x9e37_79b9_7f4a_7c15       // 別の初期値で、独立した 2 本目

    // **8 バイトずつ混ぜる。**1 バイトずつ回すと、150MB の走査だけで
    // GNU diff の総時間を超えていた（実測 0.21 秒）。ここは全バイトを必ず通るので、
    // 1 バイトあたりの手数がそのまま総時間になる。
    var k = 0
    while k + 8 <= count {
        let chunk = UnsafeRawPointer(p + k).loadUnaligned(as: UInt64.self)
        a = (a ^ chunk) &* 0x0000_0100_0000_01b3
        a ^= a >> 31
        b = (b &+ chunk) &* 0x9e37_79b9_7f4a_7c15
        b ^= b >> 29
        k += 8
    }
    // 端数は 1 つの UInt64 に詰めて、同じ手を 1 回
    var tail: UInt64 = 0
    var shift: UInt64 = 0
    while k < count {
        tail |= UInt64(p[k]) << shift
        shift += 8
        k += 1
    }
    a = (a ^ tail) &* 0x0000_0100_0000_01b3
    a ^= a >> 31
    b = (b &+ tail) &* 0x9e37_79b9_7f4a_7c15
    b ^= b >> 29

    // **長さも混ぜる。**端数を 0 で埋めているので、混ぜないと "ab" と "ab" の後ろに
    // 0 が続く行が同じ値になりうる。
    a ^= UInt64(count) &* 0x9e37_79b9_7f4a_7c15
    b = b &+ UInt64(count)
    return LineHash(a: a, b: b)
}

/// 行のハッシュ。空白（半角スペース・タブ）を飛ばして混ぜる ── 「空白無視」の比較用。
///
/// `hashBytes` の 8 バイトまとめ読みは使えない（飛ばした分だけ長さが動くので、
/// 一括で読んだチャンクをそのまま混ぜられない）。空白無視は手動で切り替える設定なので、
/// 既定の速さより「1 バイトずつでも正しく飛ばせる」ほうを取る。
@inline(__always)
func hashBytesIgnoringWhitespace(_ p: UnsafePointer<UInt8>, _ count: Int) -> LineHash {
    var a: UInt64 = 0xcbf2_9ce4_8422_2325
    var b: UInt64 = 0x9e37_79b9_7f4a_7c15
    var n: UInt64 = 0
    var k = 0
    while k < count {
        let c = p[k]
        k += 1
        if c == 0x20 || c == 0x09 { continue }             // スペース・タブは無視
        let v = UInt64(c)
        a = (a ^ v) &* 0x0000_0100_0000_01b3
        a ^= a >> 31
        b = (b &+ v) &* 0x9e37_79b9_7f4a_7c15
        b ^= b >> 29
        n += 1
    }
    // 長さは「無視した後」の文字数を混ぜる ── 空白の量そのものは同一判定に関わらせない。
    a ^= n &* 0x9e37_79b9_7f4a_7c15
    b = b &+ n
    return LineHash(a: a, b: b)
}

/// 文字列 1 行ぶんのハッシュ。テスト用。
public func hashLine(_ line: String) -> LineHash {
    let n = line.utf8.count
    // 空行でも baseAddress が取れるよう、番人を 1 バイト足しておく（長さには数えない）
    let bytes = Array(line.utf8) + [0]
    return bytes.withUnsafeBufferPointer { hashBytes($0.baseAddress!, n) }
}

/// 行に切る。**行末の種類（LF / CRLF）は落とす。**テスト用の薄い口。
///
/// 落とすのは、改行コードだけが違う 2 本を「全行が違う」と言わないため。
/// 改行コードの違いそのものを見たい場合はバイナリ比較の仕事になる。
public func splitLines(_ text: String) -> [String] {
    let s = TextSource(text: text)
    return (0..<s.count).map { s.line($0) }
}

// MARK: - 結果

/// テキスト比較の結果。**行の増減と、実際の手順**を持つ。
public struct TextDiff {
    public let left: TextSource
    public let right: TextSource
    public let ops: [DiffOp]
    /// 完全一致する削除・追加ブロックの移動対応。行番号は 0 始まり。
    public let moves: [TextMove]

    public init(left: TextSource, right: TextSource, ops: [DiffOp]) {
        self.left = left
        self.right = right
        self.ops = ops
        self.moves = TextMoveDetector.detect(left: left, right: right, ops: ops)
    }

    /// 1 行も違わない
    public var isIdentical: Bool {
        ops.allSatisfy { if case .equal = $0 { return true } else { return false } }
    }

    /// 書き換わった行数（`replace` の左右の多いほう）
    public var changed: Int {
        ops.reduce(0) { n, op in
            if case let .replace(_, lc, _, rc) = op { return n + max(lc, rc) }
            return n
        }
    }

    /// 足された行数
    public var added: Int {
        ops.reduce(0) { n, op in
            if case let .insert(_, c) = op { return n + c }
            return n
        }
    }

    /// 消された行数
    public var removed: Int {
        ops.reduce(0) { n, op in
            if case let .delete(_, c) = op { return n + c }
            return n
        }
    }
}

private enum TextMoveDetector {
    private static let minimumMoveLines = 3
    private static let maximumMoveSearchLines = 250_000
    private static let maximumMoveCandidates = 32

    private struct BlockSignature: Hashable {
        let count: Int
        let first: UInt64
        let second: UInt64
    }

    private struct BlockOccurrences {
        var removed: [Range<Int>] = []
        var added: [Range<Int>] = []
    }

    static func detect(left: TextSource, right: TextSource, ops: [DiffOp]) -> [TextMove] {
        guard withinSearchBudget(left: left, right: right, ops: ops) else { return [] }
        let blocks = changedBlocks(left: left, right: right, ops: ops)
        let moves = pairedMoves(blocks, left: left, right: right)
            .filter { $0.from.count >= minimumMoveLines }
        guard moves.count <= maximumMoveCandidates else { return [] }
        return moves.filter {
            occursExactlyOnce($0.from, in: left, matching: left)
                && occursExactlyOnce($0.from, in: right, matching: left)
        }.sorted { $0.from.lowerBound < $1.from.lowerBound }
    }

    private static func withinSearchBudget(left: TextSource, right: TextSource, ops: [DiffOp]) -> Bool {
        var changedBlocks = 0
        var changedLines = 0
        var hasDeletion = false
        var hasAddition = false
        for operation in ops {
            switch operation {
            case let .delete(_, count):
                hasDeletion = true
                changedBlocks += 1
                changedLines += count
            case let .insert(_, count):
                hasAddition = true
                changedBlocks += 1
                changedLines += count
            default:
                continue
            }
            if changedBlocks > 2_000 || changedLines > 100_000 { return false }
        }
        return hasDeletion && hasAddition
            && max(left.count, right.count) <= maximumMoveSearchLines
    }

    private static func changedBlocks(left: TextSource, right: TextSource,
                                      ops: [DiffOp]) -> [BlockSignature: BlockOccurrences] {
        var blocks: [BlockSignature: BlockOccurrences] = [:]
        for operation in ops {
            switch operation {
            case let .delete(start, count):
                let range = start..<(start + count)
                blocks[signature(left, range), default: BlockOccurrences()].removed.append(range)
            case let .insert(start, count):
                let range = start..<(start + count)
                blocks[signature(right, range), default: BlockOccurrences()].added.append(range)
            default:
                continue
            }
        }
        return blocks
    }

    private static func signature(_ source: TextSource, _ range: Range<Int>) -> BlockSignature {
        var first: UInt64 = 0x243f_6a88_85a3_08d3
        var second: UInt64 = 0x1319_8a2e_0370_7344
        for index in range {
            let hash = source.hashes[index]
            first = (first ^ hash.a) &* 0x9e37_79b9_7f4a_7c15
            first ^= first >> 29
            second = (second &+ hash.b) &* 0xbf58_476d_1ce4_e5b9
            second ^= second >> 31
        }
        return BlockSignature(count: range.count, first: first, second: second)
    }

    private static func pairedMoves(_ blocks: [BlockSignature: BlockOccurrences],
                                    left: TextSource, right: TextSource) -> [TextMove] {
        blocks.compactMap { _, occurrences -> TextMove? in
            guard occurrences.removed.count == 1, occurrences.added.count == 1,
                  let from = occurrences.removed.first, let destination = occurrences.added.first,
                  hasSameLines(from, destination, left: left, right: right) else { return nil }
            return TextMove(from: from, to: destination)
        }
    }

    private static func hasSameLines(_ leftRange: Range<Int>, _ rightRange: Range<Int>,
                                    left: TextSource, right: TextSource) -> Bool {
        guard leftRange.count == rightRange.count else { return false }
        for offset in 0..<leftRange.count
        where left.line(leftRange.lowerBound + offset) != right.line(rightRange.lowerBound + offset) {
            return false
        }
        return true
    }

    private static func occursExactlyOnce(_ range: Range<Int>, in source: TextSource,
                                          matching reference: TextSource) -> Bool {
        let pattern = Array(reference.hashes[range])
        guard !pattern.isEmpty, pattern.count <= source.count else { return false }
        let prefix = patternPrefix(pattern)
        return countExactOccurrences(pattern, prefix: prefix, in: source, reference: reference,
                                     referenceRange: range) == 1
    }

    private static func patternPrefix(_ pattern: [LineHash]) -> [Int] {
        var prefix = [Int](repeating: 0, count: pattern.count)
        var prefixLength = 0
        for index in 1..<pattern.count {
            while prefixLength > 0 && pattern[index] != pattern[prefixLength] {
                prefixLength = prefix[prefixLength - 1]
            }
            if pattern[index] == pattern[prefixLength] { prefixLength += 1 }
            prefix[index] = prefixLength
        }
        return prefix
    }

    private static func countExactOccurrences(_ pattern: [LineHash], prefix: [Int],
                                              in source: TextSource, reference: TextSource,
                                              referenceRange: Range<Int>) -> Int {
        var matchLength = 0
        var occurrences = 0
        for index in source.hashes.indices {
            while matchLength > 0 && source.hashes[index] != pattern[matchLength] {
                matchLength = prefix[matchLength - 1]
            }
            if source.hashes[index] == pattern[matchLength] { matchLength += 1 }
            guard matchLength == pattern.count else { continue }

            let start = index - pattern.count + 1
            if matchesExactly(start: start, referenceRange: referenceRange,
                              in: source, reference: reference) {
                occurrences += 1
                if occurrences > 1 { return occurrences }
            }
            matchLength = prefix[matchLength - 1]
        }
        return occurrences
    }

    private static func matchesExactly(start: Int, referenceRange: Range<Int>,
                                       in source: TextSource, reference: TextSource) -> Bool {
        for offset in 0..<referenceRange.count
        where source.line(start + offset) != reference.line(referenceRange.lowerBound + offset) {
            return false
        }
        return true
    }
}

/// そのまま移動した連続行ブロック。範囲は左右それぞれの 0 始まり行番号。
public struct TextMove: Equatable, Hashable, Sendable {
    public let from: Range<Int>
    public let destination: Range<Int>

    public init(from: Range<Int>, to destination: Range<Int>) {
        self.from = from
        self.destination = destination
    }
}

/// 2 つのテキストを比べる。
public func compareText(_ left: TextSource, _ right: TextSource) -> TextDiff {
    TextDiff(left: left, right: right,
             ops: LineDiff.compute(left.hashes, right.hashes))
}

/// 2 つの文字列を比べる。テスト・小さな入力用。
public func compareText(_ leftText: String, _ rightText: String) -> TextDiff {
    compareText(TextSource(text: leftText), TextSource(text: rightText))
}

/// ファイルを読む。**開けないときの言い方を `loadImage` と揃える。**
///
/// `Data(contentsOf:)` の投げる NSError をそのまま出すと、Domain や UserInfo が
/// 素で並んで読めない ―― 画像側は前から `error.cannot_open` に畳んでいる。
public func readFile(_ url: URL) throws -> Data {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
        throw ImageLoadError.cannotOpen(url)
    }
    return data
}
