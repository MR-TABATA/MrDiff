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
