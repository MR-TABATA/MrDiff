import XCTest
import SQLite3
@testable import MrDiffCore

/// SQLite のスキーマの比較。**本物の SQLite のファイルを作って**確かめる（模擬ではなく）。
final class SQLiteDiffTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mrdiff-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func makeDB(_ name: String, _ sql: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        return url
    }

    private func diff(_ a: String, _ b: String) throws -> SQLiteSchemaDiff {
        compareSQLiteSchemas(try readSQLiteSchema(at: try makeDB("a.db", a)), try readSQLiteSchema(at: try makeDB("b.db", b)))
    }

    func testIdenticalSchemas() throws {
        let sql = "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); CREATE INDEX i ON t(name);"
        XCTAssertTrue(try diff(sql, sql).isIdentical)
    }

    func testColumnAddedRemovedAndChanged() throws {
        let d = try diff("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, legacy TEXT);",
                         "CREATE TABLE users(id INTEGER PRIMARY KEY, name VARCHAR(80) NOT NULL DEFAULT 'x', email TEXT NOT NULL DEFAULT '');")
        XCTAssertEqual(d.tablesChanged.map(\.table), ["users"])
        let cols = Dictionary(uniqueKeysWithValues: d.tablesChanged[0].columns.map { ($0.column, $0) })
        XCTAssertEqual(cols["email"]?.kind, .added)
        XCTAssertEqual(cols["email"]?.shape, "TEXT NOT NULL DEFAULT ''")
        XCTAssertEqual(cols["legacy"]?.kind, .removed)
        let name = try XCTUnwrap(cols["name"])
        XCTAssertEqual(name.kind, .changed)
        XCTAssertTrue(name.details.contains { $0.hasPrefix("type: TEXT → VARCHAR(80)") })
        XCTAssertTrue(name.details.contains { $0.hasPrefix("NOT NULL: false → true") })
        XCTAssertTrue(name.details.contains { $0.contains("default: (none) → 'x'") })
    }

    func testTablesIndexesViewsAndTriggers() throws {
        let d = try diff("""
        CREATE TABLE gone(id INTEGER); CREATE TABLE t(id INTEGER, v INTEGER);
        CREATE INDEX i_old ON t(v); CREATE INDEX i_same ON t(id); CREATE VIEW v1 AS SELECT id FROM t;
        CREATE TRIGGER trg AFTER INSERT ON t BEGIN SELECT 1; END;
        """, """
        CREATE TABLE added(id INTEGER); CREATE TABLE t(id INTEGER, v INTEGER);
        CREATE INDEX i_new ON t(v); CREATE INDEX i_same ON t(id, v); CREATE VIEW v1 AS SELECT v FROM t;
        """)
        XCTAssertEqual(d.tablesAdded, ["added"]); XCTAssertEqual(d.tablesRemoved, ["gone"])
        XCTAssertEqual(d.indexesAdded, ["i_new"]); XCTAssertEqual(d.indexesRemoved, ["i_old"]); XCTAssertEqual(d.indexesChanged, ["i_same"])
        XCTAssertEqual(d.viewsChanged, ["v1"])
        XCTAssertEqual(d.triggersRemoved, ["trg"])
    }

    /// 改行や字下げだけの違いは、違いと言わない（`CREATE VIEW` を書き直しただけ）。
    func testWhitespaceOnlyDifferencesAreNotDifferences() throws {
        let d = try diff("CREATE TABLE t(id INTEGER); CREATE VIEW v AS SELECT id FROM t;",
                         "CREATE TABLE t(id INTEGER); CREATE VIEW v AS\n    SELECT   id\n      FROM t;")
        XCTAssertTrue(d.isIdentical)
    }

    /// 列に出ない違い（外部キー）は、「定義が変わった」と言う。
    func testConstraintOnlyChangeIsReported() throws {
        let d = try diff("CREATE TABLE p(id INTEGER PRIMARY KEY); CREATE TABLE c(id INTEGER, p INTEGER REFERENCES p(id));",
                         "CREATE TABLE p(id INTEGER PRIMARY KEY); CREATE TABLE c(id INTEGER, p INTEGER);")
        XCTAssertEqual(d.tablesChanged.map(\.table), ["c"])
        XCTAssertTrue(d.tablesChanged[0].columns.isEmpty)
        XCTAssertTrue(d.tablesChanged[0].definitionChanged)
    }

    /// SQLite 自身の管理用テーブル（AUTOINCREMENT が作る `sqlite_sequence`）は、利用者のスキーマではない。
    func testInternalTablesAreIgnored() throws {
        let schema = try readSQLiteSchema(at: try makeDB("s.db", "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT);"))
        XCTAssertEqual(Set(schema.tables.keys), ["t"])
    }

    /// **相手のフォルダにファイルを増やさない。** WAL モードの DB を読んでも `-wal` / `-shm` が残らない。
    func testReadingLeavesNoFilesBehind() throws {
        let url = try makeDB("w.db", "PRAGMA journal_mode=WAL; CREATE TABLE t(id INTEGER);")
        // 書いたあと、WAL / SHM は閉じるときに消える。開いたまま残る状態を作らず、読んだ前後を比べる。
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        _ = try readSQLiteSchema(at: url)
        let after = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(before, after)
    }

    /// 相対パス（`mrdiff a.db b.db` の形）でも開ける。以前は `a.db?immutable=1…` という基準の無い URI になって失敗した。
    func testRelativePathWorks() throws {
        _ = try makeDB("rel.db", "CREATE TABLE t(id INTEGER);")
        let old = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(dir.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(old) }
        let schema = try readSQLiteSchema(at: URL(fileURLWithPath: "rel.db"))
        XCTAssertEqual(Set(schema.tables.keys), ["t"])
    }

    func testRecognisesTheHeaderOnly() throws {
        let url = try makeDB("h.db", "CREATE TABLE t(id INTEGER);")
        XCTAssertTrue(looksLikeSQLite(try Data(contentsOf: url)))
        XCTAssertFalse(looksLikeSQLite(Data("SQLite format 2".utf8)))
        XCTAssertFalse(looksLikeSQLite(Data()))
        XCTAssertFalse(looksLikeSQLite(Data("hello".utf8)))
    }

    /// ヘッダだけ SQLite で中身が壊れているなら、読めずに投げる（呼び出し側がバイナリへ落とす）。
    func testCorruptFileThrows() throws {
        var bytes = Data("SQLite format 3\0".utf8)
        bytes.append(Data(repeating: 0xFF, count: 4096))
        let url = dir.appendingPathComponent("bad.db")
        try bytes.write(to: url)
        XCTAssertThrowsError(try readSQLiteSchema(at: url))
    }

    func testJSONSaysRowsAreNotCompared() throws {
        let d = try diff("CREATE TABLE t(id INTEGER);", "CREATE TABLE t(id INTEGER);")
        let same = JSONOutput.sqlite(d, bytesDiffer: false)
        XCTAssertEqual(same["result"] as? String, "identical")
        let bytes = JSONOutput.sqlite(d, bytesDiffer: true)
        XCTAssertEqual(bytes["result"] as? String, "differ", "スキーマが同じでもバイトが違えば、違うと言う（今までの終了コードを変えない）")
        XCTAssertEqual(bytes["schema"] as? String, "identical")
        XCTAssertEqual(bytes["rows"] as? String, "not-compared")
    }
}
