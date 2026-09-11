import Foundation

/// ローカルの公開フォルダ（git 管理下）を、サイトの URL へ対応づける。**純関数。**
///
/// ## なぜ git 管理下だけか
///
/// 「意図して置いたもの」を正にしたい。ビルドが吐いた中間物・`.DS_Store`・エディタの
/// 一時ファイルは、置いたつもりが無いのにフォルダには居る。**git が「意図」の記録**なので、
/// `git ls-files` に載っているものだけを正とする ―― こうすると、
/// **サイトにあって git に無いもの＝置き忘れ**が、突き合わせの副産物として出る。
///
/// ## 対応づけの規則
///
/// - `dir/a/b.html` は `base/a/b.html`
/// - **`index.html` は畳む。** `dir/a/index.html` は `base/a/`（多くの配信がこう出す）
/// - パスの区切りは常に `/`（URL 側）。Windows は対象外なのでここは考えない
public enum SiteMap {

    public struct Entry: Equatable {
        /// git からの相対パス（`site/a/b.html`）。
        public let localPath: String
        /// 突き合わせる URL。
        public let url: URL
    }

    /// `relativePaths` は **`git ls-files <dir>` の出力**（dir からの相対、`/` 区切り）。
    ///
    /// `base` はサイト側の根（`https://example.com` でも `https://example.com/app` でも）。
    /// 末尾スラッシュの有無は吸収する。
    public static func entries(base: URL, relativePaths: [String]) -> [Entry] {
        let root = normalizedBase(base)
        return relativePaths.compactMap { rel in
            let path = urlPath(for: rel)
            guard let url = URL(string: root + path) else { return nil }
            return Entry(localPath: rel, url: url)
        }
    }

    /// ローカルの相対パス → URL のパス部分。
    static func urlPath(for relative: String) -> String {
        var p = relative
        // `index.html` はディレクトリへ畳む。`a/index.html` → `a/`、`index.html` → ``。
        if p == "index.html" {
            return ""
        } else if p.hasSuffix("/index.html") {
            return String(p.dropLast("index.html".count))   // 末尾の "index.html" を落とす＝`a/`
        }
        return p
    }

    /// 末尾スラッシュを 1 つに揃えた base（後ろに path を素直に足せる形）。
    static func normalizedBase(_ base: URL) -> String {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s + "/"
    }
}
