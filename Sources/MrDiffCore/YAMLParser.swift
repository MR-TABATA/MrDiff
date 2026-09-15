import Foundation

/// YAML の**部分集合**だけを読む。書ける・読めると謳うものと、実際に踏んだときの挙動が
/// ずれるのが一番まずい（「浅くてもいいが、間違ってはいけない」＝ README の線）ので、
/// 掴みきれない構文に当たったら**必ず投げる**。呼び側（`parseStructured`）はそれを
/// 黙って行 diff に戻す合図として使う ―― 誤読より「構造比較を諦めた」ほうがまし。
///
/// 読めるもの: ブロックのマッピング／シーケンス（インデント）、フロー `{...}` `[...]`、
/// 素の・シングル・ダブルクォートのスカラ、コメント、`---` の先頭 1 個。
/// **読めない（投げる）:** アンカー／エイリアス（`&` `*`）、タグ（`!!str` 等）、
/// ブロックスカラ（`|` `>`）、複数ドキュメント、インデントにタブを使ったもの、マージキー
/// （`<<:`）。どれも一部の設定ファイルにしか出ず、誤読の害（「同じ」と言い切って外す）の
/// ほうが「対応していないので諦めた」より重い。
enum YAMLParser {

    struct Error: Swift.Error { let reason: String }

    // MARK: - 行に割る

    private struct Line {
        var indent: Int
        var content: String   // インデントとコメントを落とした、行の中身
    }

    static func parse(_ data: Data) throws -> StructuredValue {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error(reason: "not UTF-8")
        }
        var lines: [Line] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            guard let stripped = stripComment(s) else { throw Error(reason: "unterminated quote") }
            s = stripped
            // インデントはスペースだけ。タブが混じったら諦める（本物の YAML も禁じている）。
            // **`trimmingCharacters(.whitespaces)` はタブも落とす**ので、数える前に
            // 素の文字を見て弾く ―― でないとタブが静かに消え、誤ったインデントで読めてしまう。
            var indent = 0
            let chars = Array(s)
            while indent < chars.count, chars[indent] == " " { indent += 1 }
            if indent < chars.count, chars[indent] == "\t" { throw Error(reason: "tab in indentation") }
            let content = String(chars.dropFirst(indent)).trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }   // 空行・コメントだけの行
            if indent == 0, content == "---" {
                // **先頭（まだ 1 行も読んでいない）だけ**「最初のドキュメントの始まり」として
                // 読み飛ばす。中身を読んだ後にもう 1 個出てきたら、2 つ目のドキュメント。
                if !lines.isEmpty { throw Error(reason: "multiple documents") }
                continue
            }
            if indent == 0, content == "..." { break }   // ドキュメント終端。後ろは読まない
            if indent == 0, lines.isEmpty, content.hasPrefix("%") {
                throw Error(reason: "directive")   // %YAML 等。稀なので諦める
            }
            lines.append(Line(indent: indent, content: content))
        }
        if lines.isEmpty { return .null }
        var pos = 0
        let v = try parseBlock(&lines, &pos, minIndent: 0)
        if pos != lines.count { throw Error(reason: "trailing content (second document?)") }
        return v
    }

    /// `#` から行末までを削る。**クォートの中の `#` は消さない。**
    /// 空白の後ろか行頭の `#` だけをコメントとして扱う（`http://x#frag` のような値を守る）。
    /// クォートが閉じないまま行末に着いたら nil（＝行をまたぐ文字列は非対応）。
    private static func stripComment(_ s: String) -> String? {
        var out: [Character] = []
        var quote: Character? = nil
        var prevWasSpace = true
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                out.append(c)
                if c == q {
                    // エスケープされた同じクォートは閉じたと見なさない（`\"` `''`）
                    if q == "\"" && i > 0 && chars[i - 1] == "\\" {
                        // 直前が \\\\ （エスケープされた \）ならこの \" は本当に閉じている。
                        var backslashes = 0
                        var k = i - 1
                        while k >= 0 && chars[k] == "\\" { backslashes += 1; k -= 1 }
                        if backslashes % 2 == 1 { i += 1; continue }
                    }
                    if q == "'" && i + 1 < chars.count && chars[i + 1] == "'" {
                        // '' はエスケープ済みシングルクォート。両方出力して閉じない。
                        out.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    quote = nil
                }
                i += 1
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                out.append(c)
                i += 1
                prevWasSpace = false
                continue
            }
            if c == "#", prevWasSpace {
                return String(out)
            }
            out.append(c)
            prevWasSpace = (c == " ")
            i += 1
        }
        if quote != nil { return nil }
        return String(out)
    }

    // MARK: - ブロック

    /// 1 つのブロック（マッピング・シーケンス・裸のスカラ 1 行）を読む。
    private static func parseBlock(_ lines: inout [Line], _ pos: inout Int, minIndent: Int) throws -> StructuredValue {
        guard pos < lines.count, lines[pos].indent >= minIndent else { return .null }
        let indent = lines[pos].indent
        let content = lines[pos].content
        if isSequenceLine(content) {
            return try parseSequence(&lines, &pos, indent: indent)
        }
        if try splitMappingLine(content) != nil {
            return try parseMapping(&lines, &pos, indent: indent)
        }
        // 裸のスカラ 1 行（そのブロックはこれで終わり）。
        pos += 1
        return try parseScalarOrFlow(content)
    }

    private static func isSequenceLine(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ")
    }

    private static func parseSequence(_ lines: inout [Line], _ pos: inout Int, indent: Int) throws -> StructuredValue {
        var items: [StructuredValue] = []
        while pos < lines.count, lines[pos].indent == indent, isSequenceLine(lines[pos].content) {
            let content = lines[pos].content
            if content == "-" {
                pos += 1
                if pos < lines.count, lines[pos].indent > indent {
                    items.append(try parseBlock(&lines, &pos, minIndent: indent + 1))
                } else {
                    items.append(.null)
                }
                continue
            }
            // "- " の後ろ。何文字目からスカラが始まるかで、入れ子の仮想インデントを決める。
            let after = content.dropFirst(2)
            let leadingSpaces = after.prefix(while: { $0 == " " }).count
            let rest = String(after.dropFirst(leadingSpaces))
            let virtualIndent = indent + 2 + leadingSpaces
            if rest.isEmpty {
                pos += 1
                if pos < lines.count, lines[pos].indent > indent {
                    items.append(try parseBlock(&lines, &pos, minIndent: indent + 1))
                } else {
                    items.append(.null)
                }
                continue
            }
            if try isSequenceLine(rest) || splitMappingLine(rest) != nil {
                // `- key: value` / `- - a` ―― 同じ行にブロックの続きが始まっている。
                // その行を「仮想インデント」の行として書き換え、位置は進めずに再帰する。
                lines[pos] = Line(indent: virtualIndent, content: rest)
                items.append(try parseBlock(&lines, &pos, minIndent: virtualIndent))
                continue
            }
            items.append(try parseScalarOrFlow(rest))
            pos += 1
        }
        return .array(items)
    }

    private static func parseMapping(_ lines: inout [Line], _ pos: inout Int, indent: Int) throws -> StructuredValue {
        var entries: [String: StructuredValue] = [:]
        while pos < lines.count, lines[pos].indent == indent {
            guard let (key, rest) = try splitMappingLine(lines[pos].content) else { break }
            if key == "<<" { throw Error(reason: "merge key (<<) is not supported") }
            if rest.isEmpty {
                pos += 1
                if pos < lines.count, lines[pos].indent > indent {
                    entries[key] = try parseBlock(&lines, &pos, minIndent: indent + 1)
                } else {
                    entries[key] = .null
                }
            } else {
                entries[key] = try parseScalarOrFlow(rest)
                pos += 1
            }
        }
        return .object(entries)
    }

    /// `key: value` の形なら `(key, value)` を返す。`value` は空文字列のこともある
    /// （＝値は次の行以降のブロック）。マッピングの行でなければ nil。
    ///
    /// キーは素のトークンか、クォート文字列。区切りの `:` は**フロー `[]` `{}` の外**、
    /// かつ空白か行末が続くものだけを見る（`http://x` を key: value と誤読しない）。
    private static func splitMappingLine(_ content: String) throws -> (String, String)? {
        let chars = Array(content)
        var i = 0
        let key: String
        if chars.first == "\"" || chars.first == "'" {
            let (s, next) = try readQuoted(chars, 0)
            key = s
            i = next
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count, chars[i] == ":" else { return nil }
            i += 1
        } else {
            var depth = 0
            var end: Int? = nil
            var j = 0
            while j < chars.count {
                let c = chars[j]
                if c == "[" || c == "{" { depth += 1 }
                else if c == "]" || c == "}" { depth -= 1 }
                else if c == ":" && depth == 0 {
                    if j + 1 == chars.count || chars[j + 1] == " " { end = j; break }
                }
                j += 1
            }
            guard let e = end else { return nil }
            key = String(chars[0..<e]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { return nil }
            i = e + 1
        }
        let rest = String(chars[min(i, chars.count)...]).trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }

    // MARK: - スカラ・フロー

    private static func parseScalarOrFlow(_ text: String) throws -> StructuredValue {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") || t.hasPrefix("{") {
            let chars = Array(t)
            var i = 0
            let v = try parseFlowValue(chars, &i)
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i == chars.count else { throw Error(reason: "trailing characters after flow value") }
            return v
        }
        return try parseScalar(t)
    }

    private static func parseScalar(_ t: String) throws -> StructuredValue {
        if t.isEmpty || t == "~" || t == "null" || t == "Null" || t == "NULL" { return .null }
        if t.hasPrefix("&") || t.hasPrefix("*") { throw Error(reason: "anchors/aliases are not supported") }
        if t.hasPrefix("!") { throw Error(reason: "tags are not supported") }
        if t.hasPrefix("|") || t.hasPrefix(">") { throw Error(reason: "block scalars are not supported") }
        if t.hasPrefix("\"") {
            let chars = Array(t)
            let (s, next) = try readQuoted(chars, 0)
            guard next == chars.count else { throw Error(reason: "trailing characters after quoted string") }
            return .string(s)
        }
        if t.hasPrefix("'") {
            let chars = Array(t)
            let (s, next) = try readQuoted(chars, 0)
            guard next == chars.count else { throw Error(reason: "trailing characters after quoted string") }
            return .string(s)
        }
        if t == "true" || t == "True" || t == "TRUE" { return .bool(true) }
        if t == "false" || t == "False" || t == "FALSE" { return .bool(false) }
        if let n = parseNumber(t) { return .number(n) }
        return .string(t)
    }

    private static func parseNumber(_ t: String) -> Double? {
        guard let first = t.first, first == "-" || first == "+" || first.isNumber else { return nil }
        // Swift の Double("1_000") は通ってしまうので、数字・符号・小数点・指数だけに絞る。
        let allowed = Set("0123456789+-.eE")
        guard t.allSatisfy({ allowed.contains($0) }) else { return nil }
        return Double(t)
    }

    /// `"..."` / `'...'` を読む。閉じクォートの次の位置まで進める。
    private static func readQuoted(_ chars: [Character], _ start: Int) throws -> (String, Int) {
        let quote = chars[start]
        var i = start + 1
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if quote == "\"" {
                if c == "\\", i + 1 < chars.count {
                    let esc = chars[i + 1]
                    switch esc {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "0": out.append("\0")
                    case "u":
                        guard i + 6 <= chars.count,
                              let code = UInt32(String(chars[(i + 2)..<(i + 6)]), radix: 16),
                              let scalar = Unicode.Scalar(code) else {
                            throw Error(reason: "bad \\u escape")
                        }
                        out.append(Character(scalar))
                        i += 6
                        continue
                    default: out.append(esc)
                    }
                    i += 2
                    continue
                }
                if c == "\"" { return (out, i + 1) }
                out.append(c)
                i += 1
            } else {
                if c == "'" {
                    if i + 1 < chars.count, chars[i + 1] == "'" { out.append("'"); i += 2; continue }
                    return (out, i + 1)
                }
                out.append(c)
                i += 1
            }
        }
        throw Error(reason: "unterminated quote")
    }

    /// フロー形式 `[...]` / `{...}`。JSON に似せてあるが、クォート無しのスカラも許す
    /// （`[a, b, 1]` のような素の書き方が YAML では普通なので）。
    private static func parseFlowValue(_ chars: [Character], _ i: inout Int) throws -> StructuredValue {
        skipFlowSpace(chars, &i)
        guard i < chars.count else { throw Error(reason: "unexpected end in flow value") }
        switch chars[i] {
        case "[":
            i += 1
            var items: [StructuredValue] = []
            skipFlowSpace(chars, &i)
            if i < chars.count, chars[i] == "]" { i += 1; return .array(items) }
            while true {
                items.append(try parseFlowValue(chars, &i))
                skipFlowSpace(chars, &i)
                guard i < chars.count else { throw Error(reason: "unterminated [") }
                if chars[i] == "," { i += 1; skipFlowSpace(chars, &i); continue }
                if chars[i] == "]" { i += 1; break }
                throw Error(reason: "expected , or ] in flow sequence")
            }
            return .array(items)
        case "{":
            i += 1
            var entries: [String: StructuredValue] = [:]
            skipFlowSpace(chars, &i)
            if i < chars.count, chars[i] == "}" { i += 1; return .object(entries) }
            while true {
                skipFlowSpace(chars, &i)
                let key: String
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let (s, next) = try readQuoted(chars, i)
                    key = s
                    i = next
                } else {
                    key = try readFlowToken(chars, &i, stop: [":", ",", "}", "]"])
                }
                skipFlowSpace(chars, &i)
                guard i < chars.count, chars[i] == ":" else { throw Error(reason: "expected : in flow mapping") }
                i += 1
                let value = try parseFlowValue(chars, &i)
                entries[key] = value
                skipFlowSpace(chars, &i)
                guard i < chars.count else { throw Error(reason: "unterminated {") }
                if chars[i] == "," { i += 1; continue }
                if chars[i] == "}" { i += 1; break }
                throw Error(reason: "expected , or } in flow mapping")
            }
            return .object(entries)
        case "\"", "'":
            let (s, next) = try readQuoted(chars, i)
            i = next
            return .string(s)
        default:
            let token = try readFlowToken(chars, &i, stop: [",", "}", "]"])
            return try parseScalar(token)
        }
    }

    private static func readFlowToken(_ chars: [Character], _ i: inout Int, stop: Set<Character>) throws -> String {
        var out = ""
        while i < chars.count, !stop.contains(chars[i]) {
            out.append(chars[i])
            i += 1
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw Error(reason: "empty token in flow value") }
        return trimmed
    }

    private static func skipFlowSpace(_ chars: [Character], _ i: inout Int) {
        while i < chars.count, chars[i] == " " { i += 1 }
    }
}
