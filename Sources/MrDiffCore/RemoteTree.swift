import Foundation
import CryptoKit

/// ディレクトリ（ローカル / SSH 越し）を歩いて、**パス → 中身の指紋**を取る。
///
/// 指紋は MD5。**中身の一致を見るだけ**なので暗号強度は要らない（速いほうを採る）。
/// ディレクトリ全体をメモリに載せないため、指紋だけを持って `TreeDiff` へ渡す。
public enum RemoteTree {

    public enum TreeError: Error, CustomStringConvertible {
        case sshFailed(String)
        case notADirectory(String)
        public var description: String {
            switch self {
            case .sshFailed(let m):    return t("error.ssh_list_failed", m)
            case .notADirectory(let p): return t("error.not_a_dir", p)
            }
        }
    }

    /// ローカルのディレクトリを歩く。返すのは**dir からの相対パス → MD5**。
    public static func local(_ dir: URL) throws -> [String: String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw TreeError.notADirectory(dir.path)
        }
        let root = dir.standardizedFileURL.path
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = e?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            let rel = String(full.dropFirst(root.count + 1))
            if let data = try? Data(contentsOf: item) { out[rel] = md5(data) }
        }
        return out
    }

    /// SSH 越しにリモートのディレクトリを歩く。**find と md5 をリモートで実行して 1 往復**。
    ///
    /// ファイルごとに scp すると、1000 個で 1000 回の接続になる ―― リモートで
    /// `find … -exec md5sum` を回し、**一覧と指紋を 1 回のセッションで**取る。
    /// GNU の `md5sum`（Linux）と BSD の `md5`（macOS）で出力が違うので、両対応の
    /// 1 行スクリプトを送る。
    public static func ssh(host: String, path: String) throws -> [String: String] {
        // リモートで実行するスクリプト。パスの前後は詰め、md5 と find の差を吸収する。
        // 出力は `<hex>\t<相対パス>` の NUL 区切り。
        let script = """
        cd \(shellQuote(path)) || exit 3
        find . -type f -print0 | while IFS= read -r -d '' f; do
          h=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1) || h=$(md5 -q "$f" 2>/dev/null) || h=?
          printf '%s\\t%s\\0' "$h" "${f#./}"
        done
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ssh", "-o", "BatchMode=yes", host, script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw TreeError.sshFailed("ssh not found") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw TreeError.sshFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var result: [String: String] = [:]
        for record in data.split(separator: 0) {
            let text = String(decoding: record, as: UTF8.self)
            guard let tab = text.firstIndex(of: "\t") else { continue }
            let hash = String(text[..<tab])
            let rel = String(text[text.index(after: tab)...])
            if !rel.isEmpty { result[rel] = hash }
        }
        return result
    }

    // MARK: - 細部

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// リモートへ渡すパスを 1 引数に固める（シングルクォートで包み、中の ' を退避）。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
