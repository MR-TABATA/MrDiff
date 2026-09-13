import Foundation

/// Word の本文（`word/document.xml`）から**段落の文字だけ**を抜く。
///
/// docx は zip の中の XML で、バイトで比べても「圧縮し直された」しか分からず、
/// XML で比べても書式のタグが差分を埋める。契約書や仕様書の版比較で知りたいのは
/// 「どの段落の文言が変わったか」なので、段落を 1 行にして行 diff に掛ける。
///
/// 見るのは `w:t`（文字）と `w:tab`（タブ）だけ。書式・表の枠・画像・コメント・
/// 変更履歴の印は見ない ―― 表の中の文字は、セルごとの段落としてそのまま出る。
public enum DocxText {

    /// zip に本文があるか。
    public static let bodyPath = "word/document.xml"

    /// 段落の文字列。本文が無い・読めないなら nil。
    public static func paragraphs(in zip: ZipArchive) -> [String]? {
        guard let xml = zip.extract(bodyPath) else { return nil }
        let p = Parser()
        let parser = XMLParser(data: xml)
        parser.delegate = p
        guard parser.parse() else { return nil }
        return p.paragraphs
    }

    /// 段落を改行でつないだテキスト（`TextSource` へ渡す形）。
    public static func text(in zip: ZipArchive) -> String? {
        paragraphs(in: zip).map { $0.joined(separator: "\n") + "\n" }
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        private var current: String? = nil
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "w:p":   current = ""
            case "w:t":   inText = true
            case "w:tab": current?.append("\t")
            case "w:br", "w:cr": current?.append("\n")
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) {
            if inText { current?.append(s) }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "w:t": inText = false
            case "w:p":
                if let c = current { paragraphs.append(c) }
                current = nil
            default: break
            }
        }
    }
}
