import Foundation

/// 2 つの**ファイル集合**を突き合わせる。純関数。
///
/// `--site`（`SiteDiff`）との違いは、**両側が列挙できる**こと。HTTP はサイト側を列挙
/// できないので片方向だった。SSH・FTP・ローカル同士は両側を歩けるので、
/// **「右にあって左に無い」＝置き忘れ**も出せる。ここが「保守しているサイトの消し忘れ」を
/// 見つける肝（2026-09-11 の会話）。
///
/// どちら側を「正」とも決めない ―― 呼ぶ側が左＝手元 / 右＝リモート と読む。
public struct TreeDiff {

    public enum Status: Equatable {
        case identical
        case changed
        case onlyLeft    // 左だけ（手元にあってリモートに無い）
        case onlyRight   // 右だけ（リモートにあって手元に無い ＝ 置き忘れ）
    }

    public struct Row: Equatable {
        public let path: String
        public let status: Status
        public init(path: String, status: Status) {
            self.path = path
            self.status = status
        }
    }

    public var rows: [Row]

    /// 突き合わせ以外の道（`compare` を通さず行を直接組む）から作るための入口。
    /// **判定はここでは行わない** ―― 呼ぶ側が別の比較（例えば `StructuredDiff`）から
    /// `onlyLeft` / `onlyRight` / `changed` の形へ写すときに使う。`compare` 自身もこれを通る。
    public init(rows: [Row]) {
        self.rows = rows
    }

    public var changed: [Row]   { rows.filter { $0.status == .changed } }
    public var onlyLeft: [Row]  { rows.filter { $0.status == .onlyLeft } }
    public var onlyRight: [Row] { rows.filter { $0.status == .onlyRight } }
    public var identical: [Row] { rows.filter { $0.status == .identical } }

    public var allIdentical: Bool { rows.allSatisfy { $0.status == .identical } }

    /// 突き合わせる。`leftHash` / `rightHash` は、そのパスの中身の指紋
    /// （**無ければその側に存在しない**）。中身そのものでなく指紋にするのは、
    /// ディレクトリ全体をメモリに載せないため（呼ぶ側が md5 なりサイズ＋md5 なりを渡す）。
    ///
    /// **パスの和集合を、順序を保って**回す（左を先に、右だけのものを後ろへ）。
    public static func compare(leftPaths: [String], rightPaths: [String],
                               leftHash: (String) -> String?,
                               rightHash: (String) -> String?) -> TreeDiff {
        let rightSet = Set(rightPaths)
        var seen = Set<String>()
        var rows: [Row] = []

        for path in leftPaths {
            guard seen.insert(path).inserted else { continue }
            let l = leftHash(path)
            let r = rightSet.contains(path) ? rightHash(path) : nil
            switch (l, r) {
            case (.some(let a), .some(let b)): rows.append(Row(path: path, status: a == b ? .identical : .changed))
            case (.some, .none):               rows.append(Row(path: path, status: .onlyLeft))
            case (.none, .some):               rows.append(Row(path: path, status: .onlyRight))
            case (.none, .none):               break   // どちらにも無い＝入力の取り違え。落とす
            }
        }
        // 右だけにあるもの（＝置き忘れ）。左のループで拾えなかったぶん。
        for path in rightPaths where !seen.contains(path) {
            seen.insert(path)
            if rightHash(path) != nil { rows.append(Row(path: path, status: .onlyRight)) }
        }
        return TreeDiff(rows: rows)
    }
}
