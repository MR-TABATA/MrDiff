import Foundation

/// 人が読む文だけを訳す。**機械が読む出力（`--json`・終了コード）は通さない。**
///
/// 通してしまうと、`grep "differ"` を書いた人のスクリプトが日本語環境で壊れる。
/// git が porcelain と人向けの出力を分けているのと同じ線を、ここで引く。
///
/// **既定は英語。** `LANG` は見ない ―― 環境で勝手に切り替わると、出力を Issue に
/// 貼った人が誰にも助けてもらえなくなる。日本語は明示的に選んだときだけ。
///
///     MRDIFF_LANG=ja mrdiff a.png b.png
///
/// SPM が生成するリソースバンドルの Info.plist には `CFBundleLocalizations` が
/// 載らないので、`Bundle.module` の自動ネゴシエーションは常に開発言語へ落ちる。
/// そこで `*.lproj` を自分で選んで直接読む（MrEditor で踏んで直したのと同じ穴）。

public enum Lang {
    /// いま使う言語。`MRDIFF_LANG` が `ja` で始まれば日本語、それ以外は英語。
    /// `--lang=` で 1 回だけ変えられる（`select`）―― 環境変数より優先。
    public private(set) static var current: String = normalize(
        ProcessInfo.processInfo.environment["MRDIFF_LANG"] ?? "en")

    /// 受け付ける言語。`--lang=` の検査もこれで。
    public static let supported = ["en", "ja"]

    /// `ja_JP.UTF-8` も `ja` も日本語。それ以外は英語。
    static func normalize(_ raw: String) -> String {
        raw.lowercased().hasPrefix("ja") ? "ja" : "en"
    }

    /// `--lang=ja` で切り替える。**訳す前に呼ぶ**（`t()` はその場で引く）。
    public static func select(_ raw: String) {
        current = normalize(raw)
        bundle = load(current)
    }

    static var bundle: Bundle = load(current)

    private static func load(_ lang: String) -> Bundle {
        if let path = Bundle.module.path(forResource: lang, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        return Bundle.module
    }
}

/// 訳を引く。**鍵が無ければ鍵そのものを返す**（黙って空文字にしない）。
public func t(_ key: String) -> String {
    Lang.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// 差し込みつき。
public func t(_ key: String, _ args: CVarArg...) -> String {
    String(format: t(key), locale: Locale(identifier: Lang.current), arguments: args)
}
