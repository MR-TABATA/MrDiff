import Foundation

/// エラーに出すファイルのパスの見せ方。**既定は今までどおり（絶対パス）。**
///
/// `--relative` を付けると、カレントディレクトリの下にあるファイルは、そこからの相対パスで言う。
/// CI のログに `/home/runner/work/…` が並ぶと、どのファイルの話か読みにくい、という要望から。
/// 画面に出るパスは、実際にはエラーの中だけ（比較の結果はフォルダの相対パスで言うか、パスを出さない）。
public enum PathDisplay {
    /// `--relative` のとき true。
    public static var relativeToCurrentDirectory = false

    public static func text(_ url: URL) -> String {
        relativeToCurrentDirectory
            ? relative(url.path, to: FileManager.default.currentDirectoryPath)
            : url.path
    }

    /// `path` が `base` の下なら相対に、そうでなければ**そのまま**（`../` は使わない：かえって読みにくい）。
    public static func relative(_ path: String, to base: String) -> String {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        if path == b { return "." }
        let prefix = b + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
