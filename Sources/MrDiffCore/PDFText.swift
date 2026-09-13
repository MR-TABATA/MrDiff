import Foundation

#if canImport(PDFKit)
import PDFKit

/// PDF の**文字**を、ページごとの行として抜く。
///
/// 見た目の比較（`PDFDiff.swift`）は「どのページの、どのあたりが」までしか言えない。
/// 契約書で知りたいのは「第 3 条の納期が変わった」なので、文字を抜いて行 diff に掛ける
/// ―― Word の段落 diff（`DocxText`）と同じ形。行の切り方は PDFKit（`PDFPage.string`）の
/// もので、書き出した道具によっては文字の順が崩れる。それでも「同じ文言か」は言える。
///
/// ページの境には `[p.N]` の行を挟む。diff の文脈にそのまま出るので、変わった行が
/// どのページのものかが読める。
public enum PDFText {

    /// 文字を持たない PDF（画像だけのスキャン）なら nil。**空の PDF を「同じ」と言わない**ため。
    public static func lines(in data: Data) -> [String]? {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return nil }
        var out: [String] = []
        var any = false
        for i in 0..<doc.pageCount {
            out.append("[p.\(i + 1)]")
            guard let page = doc.page(at: i) else { continue }
            if let s = page.string {
                for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.isEmpty { continue }
                    out.append(line)
                    any = true
                }
            }
            // 注釈と記入欄。校正の書き込み（FreeText・コメント）や、フォームに打った値は
            // 本文ではないが文言で、`string` には出ない。実物で「消えた 3 文字」が注釈だった。
            for a in page.annotations {
                let text = (a.widgetStringValue ?? a.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                out.append("[\(a.type ?? "annotation")] \(text)")
                any = true
            }
        }
        return any ? out : nil
    }

    /// 行を改行でつないだテキスト（`TextSource` へ渡す形）。
    public static func text(in data: Data) -> String? {
        lines(in: data).map { $0.joined(separator: "\n") + "\n" }
    }
}
#endif
