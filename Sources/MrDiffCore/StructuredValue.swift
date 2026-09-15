import Foundation

/// JSON / YAML を読んだあとの共通の形。**比較のロジック（`StructuredDiff`）はここより先を
/// 見ない** ―― JSON パーサも YAML パーサも、この木に落としてしまえば同じ道を通る。
///
/// オブジェクトのキーの並びは持たない（`[String: StructuredValue]`）。JSON も YAML も
/// キーの並びに意味を持たせない仕様なので、「並びだけ違う」を差分として出さないための選択。
public indirect enum StructuredValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([StructuredValue])
    case object([String: StructuredValue])

    /// 種類だけを比べたいときの名前（`changed` の判定で使う）。
    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

// MARK: - JSON

/// JSON は `JSONSerialization`（Foundation）に任せる。**自前で書き直さない** ―― JSON の
/// エスケープ・サロゲートペア・指数表記まで手で正しく書くのは割に合わず、`--json` の出力側
/// (`JSONOutput.swift`) も同じ道具を使っている。
enum JSONStructured {
    static func parse(_ data: Data) -> StructuredValue? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return convert(obj)
    }

    private static func convert(_ obj: Any) -> StructuredValue {
        switch obj {
        case is NSNull:
            return .null
        case let n as NSNumber:
            // `true` / `false` も `NSNumber` の皮を被って届く。CFBoolean かどうかで見分ける
            // ―― `n.doubleValue` だけだと bool と 0/1 の数値が区別できない。
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case let arr as [Any]:
            return .array(arr.map(convert))
        case let dict as [String: Any]:
            return .object(dict.mapValues(convert))
        default:
            return .null
        }
    }
}

// MARK: - 判定に使う入口

/// テキストとして読めたバイト列を、JSON として、だめなら YAML として読んでみる。
/// **どちらでもなければ nil** ―― 呼び側はそのとき黙って行 diff に戻る（今までどおり）。
///
/// 先頭が `{` や `[` で始まらない・素の文字列や数だけの入力は弾く（`isTopLevelStructured`）。
/// 普通の英文が 1 単語だけの YAML として通ってしまう事故を防ぐための線で、
/// 実在する設定ファイル（オブジェクトか配列がトップレベル）はここに当たらない。
public func parseStructured(_ data: Data) -> (StructuredValue, String)? {
    if let v = JSONStructured.parse(data), isTopLevelStructured(v) {
        return (v, "json")
    }
    if let v = try? YAMLParser.parse(data), isTopLevelStructured(v) {
        return (v, "yaml")
    }
    return nil
}

private func isTopLevelStructured(_ v: StructuredValue) -> Bool {
    switch v {
    case .array, .object: return true
    case .null, .bool, .number, .string: return false
    }
}

// MARK: - 短い表示

/// 1 つの値を、1 行に収まる長さの文字列にする。**言葉を持たない**（`[3 items]` のような
/// 英単語を埋め込むと、日本語の行に混じる ―― ここは訳の外なので）。中身はコンパクトな
/// JSON そのもの：スカラはそのまま、入れ子はキーをソートして詰める（並びは差分に出さない
/// のと同じ理由）。長ければ `maxLength` で切って `…` を足す。
public func shortDescription(_ v: StructuredValue, maxLength: Int = 60) -> String {
    let full = compactJSON(v)
    guard full.count > maxLength else { return full }
    return String(full.prefix(maxLength)) + "…"
}

private func compactJSON(_ v: StructuredValue) -> String {
    switch v {
    case .null:
        return "null"
    case .bool(let b):
        return b ? "true" : "false"
    case .number(let n):
        return numberString(n)
    case .string(let s):
        return quoteJSON(s)
    case .array(let items):
        return "[" + items.map(compactJSON).joined(separator: ",") + "]"
    case .object(let entries):
        let keys = entries.keys.sorted()
        return "{" + keys.map { quoteJSON($0) + ":" + compactJSON(entries[$0]!) }.joined(separator: ",") + "}"
    }
}

private func numberString(_ n: Double) -> String {
    if n.truncatingRemainder(dividingBy: 1) == 0, abs(n) < 1e15 {
        return String(Int64(n))
    }
    return String(n)
}

// MARK: - 正規化した整形（キーの並びを揃えたテキスト）

/// キーをソートして 2 スペースで整形した JSON テキスト。**行 diff の入力に使うためのもの**
/// ―― GUI 側（MrkDiff）が、構造で判定しつつも見せ方は行 diff のまま使いたいときに要る。
/// 両側をこれに通してから比べれば、「キーの順だけ違う」は同じ文字列になって差分に出ない。
/// 数値・文字列の書き方も揃える（`1` と `1.0` はどちらも `1` になる）ので、書式の揺れも消える。
public func prettyPrint(_ v: StructuredValue, indent: Int = 0) -> String {
    let pad = String(repeating: "  ", count: indent)
    switch v {
    case .null:
        return "null"
    case .bool(let b):
        return b ? "true" : "false"
    case .number(let n):
        return numberString(n)
    case .string(let s):
        return quoteJSON(s)
    case .array(let items):
        guard !items.isEmpty else { return "[]" }
        let childPad = String(repeating: "  ", count: indent + 1)
        let body = items.map { childPad + prettyPrint($0, indent: indent + 1) }.joined(separator: ",\n")
        return "[\n" + body + "\n" + pad + "]"
    case .object(let entries):
        guard !entries.isEmpty else { return "{}" }
        let childPad = String(repeating: "  ", count: indent + 1)
        let keys = entries.keys.sorted()
        let body = keys.map { childPad + quoteJSON($0) + ": " + prettyPrint(entries[$0]!, indent: indent + 1) }.joined(separator: ",\n")
        return "{\n" + body + "\n" + pad + "}"
    }
}

private func quoteJSON(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}
