import Foundation

/// git 管理下のファイル一覧を取る。
///
/// `git ls-files` を呼ぶだけ。**自前で `.git` を読まない** ―― サブモジュールや
/// `core.quotepath`、`.gitignore` の解釈を再実装するのは、git にやらせれば済む。
public enum GitFiles {

    public enum GitError: Error, CustomStringConvertible {
        case notAGitRepo(String)
        case gitFailed(String)
        case gitNotFound

        public var description: String {
            switch self {
            case .notAGitRepo(let p): return t("error.not_git", p)
            case .gitFailed(let m):   return t("error.git_failed", m)
            case .gitNotFound:        return t("error.git_missing")
            }
        }
    }

    /// `dir` の中の、git 管理下のファイルを **dir からの相対パス**で返す。
    ///
    /// `dir` が作業ツリーの外なら弾く（＝手元にソースがある＝自分に権限のあるサイト、
    /// という前提を、ここで担保する）。
    public static func tracked(in dir: URL) throws -> [String] {
        // `-z` で NUL 区切り。ファイル名に改行が入っていても割れない。
        let out = try run(["git", "-C", dir.path, "ls-files", "-z"], cwd: dir)
        return out.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - git を呼ぶ

    private static func run(_ argv: [String], cwd: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.currentDirectoryURL = cwd
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw GitError.gitNotFound }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            if errText.contains("not a git repository") {
                throw GitError.notAGitRepo(cwd.path)
            }
            throw GitError.gitFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
