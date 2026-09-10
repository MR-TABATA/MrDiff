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
    public init(data: Data) {
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
                    hs.append(hashBytes(base + start, end - start))
                    start = i + 1
                }
                i += 1
            }
            // 末尾に改行が無ければ、残りが最後の 1 行
            if start < n {
                var end = n
                if end > start && base[end - 1] == 0x0D { end -= 1 }
                ranges.append(start..<end)
                hs.append(hashBytes(base + start, end - start))
            }
        }

        self.data = data
        self.lines = ranges
        self.hashes = hs
    }

    /// 文字列から。テスト・小さな入力用。
    public init(text: String) {
        self.init(data: Data(text.utf8))
    }

    /// ファイルから。**`mappedIfSafe` で開く** ―― 中身を常駐メモリへ写さない。
    public static func load(_ url: URL) throws -> TextSource {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ImageLoadError.cannotOpen(url)
        }
        return TextSource(data: data)
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

    public init(left: TextSource, right: TextSource, ops: [DiffOp]) {
        self.left = left
        self.right = right
        self.ops = ops
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
