import Foundation

/// テキストの比較。**行に切って、ハッシュにして、`LineDiff` へ渡す**までを持つ。
///
/// 差分そのものの計算は `LineDiff`（MrEditor からの写し）が持っていて、ここはその前後
/// ―― 読み込み・行分割・ハッシュ・数え上げ ―― だけを受け持つ。表示は CLI 側。

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
public func detectKind(_ data: Data) -> FileKind {
    if data.contains(0) { return .other }
    return String(data: data, encoding: .utf8) != nil ? .text : .other
}

// MARK: - 行

/// 行に切る。**行末の種類（LF / CRLF）は落とす。**
///
/// 落とすのは、改行コードだけが違う 2 本を「全行が違う」と言わないため。
/// 改行コードの違いそのものを見たい場合はバイナリ比較の仕事になる。
///
/// 末尾に改行があってもなくても、行数は同じ（`"a\n"` も `"a"` も 1 行）。
public func splitLines(_ text: String) -> [String] {
    if text.isEmpty { return [] }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }     // 末尾の改行は行を増やさない
    return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
}

/// 行のハッシュ。**FNV-1a を 2 通り回して 128 ビットにする。**
///
/// 64 ビットだと大きなファイルで誕生日衝突が現実的な確率に乗る。diff の衝突は
/// 「違う行を同じと言う」＝**黙って差分を見落とす**ことなので、そこは払う
/// （`LineDiff.LineHash` の注記と同じ理由）。
public func hashLine(_ line: String) -> LineHash {
    var a: UInt64 = 0xcbf2_9ce4_8422_2325       // FNV offset basis
    var b: UInt64 = 0x9e37_79b9_7f4a_7c15       // 別の初期値で、独立した 2 本目
    for byte in line.utf8 {
        a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        b = (b &+ UInt64(byte)) &* 0x00000000_01000193
        b ^= b >> 29
    }
    return LineHash(a: a, b: b)
}

// MARK: - 結果

/// テキスト比較の結果。**行の増減と、実際の手順**を持つ。
public struct TextDiff: Sendable {
    public let left: [String]
    public let right: [String]
    public let ops: [DiffOp]

    public init(left: [String], right: [String], ops: [DiffOp]) {
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

/// 2 つの文字列を比べる。
public func compareText(_ leftText: String, _ rightText: String) -> TextDiff {
    let l = splitLines(leftText)
    let r = splitLines(rightText)
    let ops = LineDiff.compute(l.map(hashLine), r.map(hashLine))
    return TextDiff(left: l, right: r, ops: ops)
}

/// ファイルを読む。**開けないときの言い方を `loadImage` と揃える。**
///
/// `Data(contentsOf:)` の投げる NSError をそのまま出すと、Domain や UserInfo が
/// 素で並んで読めない ―― 画像側は前から `error.cannot_open` に畳んでいる。
public func readFile(_ url: URL) throws -> Data {
    guard let data = try? Data(contentsOf: url) else {
        throw ImageLoadError.cannotOpen(url)
    }
    return data
}
