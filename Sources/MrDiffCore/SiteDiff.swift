import Foundation

/// git 管理下の公開フォルダと、公開中のサイトを突き合わせる。
///
/// **git が「意図」の記録。** git に載っているものが、サイトにあるべきもの。
/// この 3 つを分けて出す ―― どれも運用で別の意味を持つ。
///
/// - `missing`   … git にあってサイトに無い ＝ **デプロイ漏れ**
/// - `changed`   … 両方にあるが中身が違う ＝ **同期ズレ**
/// - `identical` … 両方にあって同じ
///
/// **git に無いのにサイトにあるもの（置き忘れ）は、この突き合わせでは出せない。**
/// URL の一覧が取れないため（HTTP にディレクトリ一覧が無い）。そのことは呼ぶ側が言う。
public struct SiteDiff {

    public enum Status: Equatable {
        case identical
        case changed
        case missing        // git にあってサイトに無い（404）
        case error(String)  // 取れなかった（500・タイムアウトなど）。**同期の判断から外す**
    }

    public struct Row: Equatable {
        public let entry: SiteMap.Entry
        public let status: Status
    }

    public var rows: [Row]

    public var missing: [Row]   { rows.filter { $0.status == .missing } }
    public var changed: [Row]   { rows.filter { $0.status == .changed } }
    public var errored: [Row]   { rows.filter { if case .error = $0.status { true } else { false } } }
    public var identical: [Row] { rows.filter { $0.status == .identical } }

    /// **全部そろっているか。** error は「分からなかった」であって「同じ」ではないので、
    /// 1 つでも error があれば同期しているとは言えない。
    public var allInSync: Bool {
        rows.allSatisfy { $0.status == .identical }
    }

    /// サイト側から 1 つ取った結果。
    public enum Remote: Equatable {
        case got(Data)        // 200
        case absent           // 404 ＝ サイトに無い
        case failed(String)   // 取れなかった（500・タイムアウトなど）
    }

    /// 1 ファイルぶんの突き合わせ。`fetch` は差し替えられる（テストは本物を叩かない）。
    /// 中身が同じかは**バイト一致**で決める ―― サイト diff は「同期しているか」を見るもので、
    /// 「1 画素の違い」を数える段ではない（それは個別に `mrdiff a b` を打つ仕事）。
    public static func compare(entries: [SiteMap.Entry],
                               fetch: (URL) -> Remote,
                               local: (String) -> Data?) -> SiteDiff {
        var rows: [Row] = []
        for e in entries {
            let status: Status
            switch fetch(e.url) {
            case .failed(let why):
                status = .error(why)
            case .absent:
                status = .missing                       // 404
            case .got(let remote):
                if let here = local(e.localPath) {
                    status = (here == remote) ? .identical : .changed
                } else {
                    // git に載っているのに手元で読めない（消えた等）。取り違えないよう error。
                    status = .error(e.localPath)
                }
            }
            rows.append(Row(entry: e, status: status))
        }
        return SiteDiff(rows: rows)
    }
}
