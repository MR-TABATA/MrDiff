import Foundation
import SQLite3

/// SQLite のスキーマの比較。**スキーマだけ**（テーブル・列・索引・ビュー・トリガ）。行のデータは比べない。
///
/// これまで SQLite のファイルは、ただのバイナリとして「何箇所違う」と言っていた。テーブルや列が増えた・
/// 減ったのか、行が変わっただけなのかは、そこからは読めない。**先にスキーマだけ**を言う
/// （行の比較は、主キー・大きなテーブルで重い。反応を見てから ―― ロードマップ）。
///
/// ## ファイルを汚さない
///
/// `?immutable=1&mode=ro` で開く。読み取り専用で、**`-wal` / `-shm` / ジャーナルを、隣に作らない**
/// （比べるだけの道具が、相手のフォルダにファイルを増やしてはいけない）。
public func looksLikeSQLite(_ data: Data) -> Bool {
    data.count >= 16 && data.prefix(16) == Data("SQLite format 3\0".utf8)
}

public struct SQLiteColumn: Equatable {
    public let name: String
    public let type: String
    public let notNull: Bool
    public let defaultValue: String?
    /// 主キーの何番目か（0 = 主キーでない）。
    public let primaryKey: Int
}

public struct SQLiteTable {
    public let name: String
    public let columns: [SQLiteColumn]
    /// `CREATE TABLE …`（空白を畳んだもの）。列に出ない違い（制約・外部キー）を拾うため。
    public let sql: String
}

public struct SQLiteSchema {
    public var tables: [String: SQLiteTable] = [:]
    /// 索引名 → (テーブル, 定義)
    public var indexes: [String: (table: String, sql: String)] = [:]
    public var views: [String: String] = [:]
    public var triggers: [String: (table: String, sql: String)] = [:]
}

public enum SQLiteError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case failed(String)
    public var description: String {
        switch self {
        case .cannotOpen(let why): return t("error.sqlite_open", why)
        case .failed(let why): return t("error.sqlite_read", why)
        }
    }
}

/// 空白の連なりを 1 つにする。**意味の無い違い（改行・字下げ）を、違いと言わない**ため。
private func squash(_ sql: String) -> String {
    sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

public func readSQLiteSchema(at url: URL) throws -> SQLiteSchema {
    // **絶対パスにしてから** URI にする。相対パス（`mrdiff a.db b.db`）のまま組むと、`a.db?immutable=1…` という
    // 基準の無い URI になって開けない。
    var comps = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false)
    comps?.query = "immutable=1&mode=ro"
    guard let uri = comps?.string else { throw SQLiteError.cannotOpen(url.path) }
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
    defer { sqlite3_close(db) }
    guard rc == SQLITE_OK, let db else {
        throw SQLiteError.cannotOpen(db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)")
    }

    func rows(_ sql: String) throws -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.failed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [[String?]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw SQLiteError.failed(String(cString: sqlite3_errmsg(db))) }
            out.append((0..<sqlite3_column_count(stmt)).map { i in
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            })
        }
        return out
    }

    var schema = SQLiteSchema()
    // `sqlite_` で始まるのは SQLite 自身の管理用（`sqlite_sequence` など）。利用者のスキーマではない。
    let master = try rows("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")
    for r in master {
        guard let type = r[0], let name = r[1] else { continue }
        let table = r[2] ?? "", sql = squash(r[3] ?? "")
        switch type {
        case "table":
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            // 生成列・隠し列も含めて見る（`table_xinfo`）。cid, name, type, notnull, dflt_value, pk, hidden
            let cols = try rows("PRAGMA table_xinfo(\(quoted))").compactMap { c -> SQLiteColumn? in
                guard let n = c[1] else { return nil }
                return SQLiteColumn(name: n, type: c[2] ?? "", notNull: c[3] == "1",
                                    defaultValue: c[4], primaryKey: Int(c[5] ?? "0") ?? 0)
            }
            schema.tables[name] = SQLiteTable(name: name, columns: cols, sql: sql)
        case "index":
            // 自動で作られる索引（`sql` が NULL）は、テーブルの定義の一部なので数えない
            if r[3] != nil { schema.indexes[name] = (table, sql) }
        case "view": schema.views[name] = sql
        case "trigger": schema.triggers[name] = (table, sql)
        default: break
        }
    }
    return schema
}

// MARK: - 比べる

public struct SQLiteColumnChange: Equatable {
    public enum Kind: String { case added, removed, changed }
    public let column: String
    public let kind: Kind
    /// `changed` のとき、何がどう変わったか（`type: TEXT → VARCHAR(80)`）。
    public let details: [String]
    /// added / removed のとき、その列の姿（`TEXT NOT NULL`）。
    public let shape: String?
}

public struct SQLiteTableChange {
    public let table: String
    public let columns: [SQLiteColumnChange]
    /// 列には出ない違い（制約・外部キーなど）で `CREATE TABLE` の文が変わった。
    public let definitionChanged: Bool
}

public struct SQLiteSchemaDiff {
    public var tablesAdded: [String] = []
    public var tablesRemoved: [String] = []
    public var tablesChanged: [SQLiteTableChange] = []
    public var indexesAdded: [String] = []
    public var indexesRemoved: [String] = []
    public var indexesChanged: [String] = []
    public var viewsAdded: [String] = [], viewsRemoved: [String] = [], viewsChanged: [String] = []
    public var triggersAdded: [String] = [], triggersRemoved: [String] = [], triggersChanged: [String] = []

    public var isIdentical: Bool {
        tablesAdded.isEmpty && tablesRemoved.isEmpty && tablesChanged.isEmpty
            && indexesAdded.isEmpty && indexesRemoved.isEmpty && indexesChanged.isEmpty
            && viewsAdded.isEmpty && viewsRemoved.isEmpty && viewsChanged.isEmpty
            && triggersAdded.isEmpty && triggersRemoved.isEmpty && triggersChanged.isEmpty
    }
}

func describe(_ c: SQLiteColumn) -> String {
    var s = c.type.isEmpty ? "(no type)" : c.type
    if c.notNull { s += " NOT NULL" }
    if let d = c.defaultValue { s += " DEFAULT \(d)" }
    if c.primaryKey > 0 { s += " PRIMARY KEY" }
    return s
}

public func compareSQLiteSchemas(_ a: SQLiteSchema, _ b: SQLiteSchema) -> SQLiteSchemaDiff {
    var d = SQLiteSchemaDiff()
    let ta = Set(a.tables.keys), tb = Set(b.tables.keys)
    d.tablesAdded = tb.subtracting(ta).sorted()
    d.tablesRemoved = ta.subtracting(tb).sorted()
    for name in ta.intersection(tb).sorted() {
        let x = a.tables[name]!, y = b.tables[name]!
        let ca = Dictionary(x.columns.map { ($0.name, $0) }, uniquingKeysWith: { f, _ in f })
        let cb = Dictionary(y.columns.map { ($0.name, $0) }, uniquingKeysWith: { f, _ in f })
        var changes: [SQLiteColumnChange] = []
        // 列の並びは、B の並びで（A にだけある列は、そのあとに）。
        for col in y.columns {
            if let old = ca[col.name] {
                if old != col {
                    var details: [String] = []
                    if old.type != col.type { details.append("type: \(old.type.isEmpty ? "(none)" : old.type) → \(col.type.isEmpty ? "(none)" : col.type)") }
                    if old.notNull != col.notNull { details.append("NOT NULL: \(old.notNull) → \(col.notNull)") }
                    if old.defaultValue != col.defaultValue { details.append("default: \(old.defaultValue ?? "(none)") → \(col.defaultValue ?? "(none)")") }
                    if old.primaryKey != col.primaryKey { details.append("primary key: \(old.primaryKey) → \(col.primaryKey)") }
                    changes.append(SQLiteColumnChange(column: col.name, kind: .changed, details: details, shape: nil))
                }
            } else {
                changes.append(SQLiteColumnChange(column: col.name, kind: .added, details: [], shape: describe(col)))
            }
        }
        for col in x.columns where cb[col.name] == nil {
            changes.append(SQLiteColumnChange(column: col.name, kind: .removed, details: [], shape: describe(col)))
        }
        let defChanged = x.sql != y.sql && changes.isEmpty
        if !changes.isEmpty || defChanged {
            d.tablesChanged.append(SQLiteTableChange(table: name, columns: changes, definitionChanged: defChanged))
        }
    }
    let ia = Set(a.indexes.keys), ib = Set(b.indexes.keys)
    d.indexesAdded = ib.subtracting(ia).sorted()
    d.indexesRemoved = ia.subtracting(ib).sorted()
    d.indexesChanged = ia.intersection(ib).filter { a.indexes[$0]!.sql != b.indexes[$0]!.sql }.sorted()
    let va = Set(a.views.keys), vb = Set(b.views.keys)
    d.viewsAdded = vb.subtracting(va).sorted(); d.viewsRemoved = va.subtracting(vb).sorted()
    d.viewsChanged = va.intersection(vb).filter { a.views[$0]! != b.views[$0]! }.sorted()
    let ga = Set(a.triggers.keys), gb = Set(b.triggers.keys)
    d.triggersAdded = gb.subtracting(ga).sorted(); d.triggersRemoved = ga.subtracting(gb).sorted()
    d.triggersChanged = ga.intersection(gb).filter { a.triggers[$0]!.sql != b.triggers[$0]!.sql }.sorted()
    return d
}

// MARK: - JSON

extension JSONOutput {
    /// `bytesDiffer`: 2 つのファイルがバイトで違うか（スキーマが同じでも、行や並びが違えば true）。
    public static func sqlite(_ d: SQLiteSchemaDiff, bytesDiffer: Bool) -> [String: Any] {
        var o: [String: Any] = ["kind": "sqlite-schema"]
        o["schema"] = d.isIdentical ? "identical" : "differ"
        o["result"] = (d.isIdentical && !bytesDiffer) ? "identical" : "differ"
        // 行は比べていない。スキーマが同じでバイトが違うとき、その中身（行・並び）は分からない、と機械にも言う。
        o["rows"] = "not-compared"
        if !d.isIdentical {
            o["tables"] = [
                "added": d.tablesAdded, "removed": d.tablesRemoved,
                "changed": d.tablesChanged.map { c -> [String: Any] in
                    ["table": c.table, "definition_changed": c.definitionChanged,
                     "columns": c.columns.map { ch -> [String: Any] in
                        var row: [String: Any] = ["column": ch.column, "status": ch.kind.rawValue]
                        if !ch.details.isEmpty { row["details"] = ch.details }
                        if let s = ch.shape { row["shape"] = s }
                        return row
                     }]
                },
            ]
            o["indexes"] = ["added": d.indexesAdded, "removed": d.indexesRemoved, "changed": d.indexesChanged]
            o["views"] = ["added": d.viewsAdded, "removed": d.viewsRemoved, "changed": d.viewsChanged]
            o["triggers"] = ["added": d.triggersAdded, "removed": d.triggersRemoved, "changed": d.triggersChanged]
        }
        return o
    }
}
