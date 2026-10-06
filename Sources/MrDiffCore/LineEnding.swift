import Foundation

/// ファイルの改行コード。**違いを黙って飲まないために、種類を言えるようにしておく。**
///
/// テキスト diff は行末の CR を落として行を切るので、CRLF と LF は同じ扱いで「違いなし」になる
/// （`TextSource`）。それは意図した挙動だが、**バイトは違うのに「No differences」とだけ言う**のは、
/// 緩めて比べたならそう言う、という線に反する。そこで、種類が違うときは注記を添える。
///
/// **直さないこと**: CR だけの行区切り（古い Mac 形式）は、いまも行に切らない。1 本の長い行になる。
/// それは注記で「そう読んでいる」と言うにとどめる（2026-10-06 決定）。
public enum LineEnding: String {
    case lf = "LF"
    case crlf = "CRLF"
    /// CR だけ（古い Mac）。**行区切りとしては扱わない。**
    case cr = "CR"
    /// 上のうち 2 種類以上が混ざっている。
    case mixed = "mixed"
    /// 改行が 1 つも無い（1 行だけのファイル）。
    case none = "none"

    /// 最初に 2 種類目が見つかった時点で打ち切る（混ざっていれば全部は見ない）。
    public static func detect(_ data: Data) -> LineEnding {
        var hasLF = false, hasCRLF = false, hasCR = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            while i < n {
                let b = p[i]
                if b == 0x0A {
                    if i > 0 && p[i - 1] == 0x0D { hasCRLF = true } else { hasLF = true }
                } else if b == 0x0D {
                    if !(i + 1 < n && p[i + 1] == 0x0A) { hasCR = true }
                }
                if (hasLF ? 1 : 0) + (hasCRLF ? 1 : 0) + (hasCR ? 1 : 0) > 1 { return }
                i += 1
            }
        }
        let kinds = (hasLF ? 1 : 0) + (hasCRLF ? 1 : 0) + (hasCR ? 1 : 0)
        if kinds > 1 { return .mixed }
        if hasCRLF { return .crlf }
        if hasLF { return .lf }
        if hasCR { return .cr }
        return .none
    }

    /// 2 つの改行コードが**違う**ときだけ返す。片方に改行が無い（1 行だけ）なら、違いとは言わない。
    public static func difference(_ a: Data, _ b: Data) -> (a: LineEnding, b: LineEnding)? {
        let ea = detect(a), eb = detect(b)
        if ea == .none || eb == .none || ea == eb { return nil }
        return (ea, eb)
    }
}
