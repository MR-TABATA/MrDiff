import Foundation
import MrDiffCore
import PostgresNIO

public enum PostgresDiffMode: String, Codable, Sendable {
    case schema
    case data
    case both
}

public struct PostgresTableSelection: Decodable, Equatable, Sendable {
    public let table: String
    public let key: [String]
    public let columns: [String]

    public init(table: String, key: [String], columns: [String]) {
        self.table = table
        self.key = key
        self.columns = columns
    }
}

public struct PostgresDiffConfiguration: Decodable, Sendable {
    public let tables: [PostgresTableSelection]

    public static func read(from url: URL) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch {
            throw PostgresDiffError.invalidConfiguration(error.localizedDescription)
        }
    }

    public func validate() throws {
        guard !tables.isEmpty else { throw PostgresDiffError.invalidConfiguration("tables must not be empty") }
        var seenTables = Set<String>()
        for selection in tables {
            guard !selection.table.isEmpty, !selection.key.isEmpty, !selection.columns.isEmpty else {
                throw PostgresDiffError.invalidConfiguration(
                    "each table needs a table name, a primary key, and at least one compared column"
                )
            }
            guard seenTables.insert(selection.table).inserted else {
                throw PostgresDiffError.invalidConfiguration("duplicate table: \(selection.table)")
            }
            guard Set(selection.key).count == selection.key.count,
                  Set(selection.columns).count == selection.columns.count else {
                throw PostgresDiffError.invalidConfiguration("duplicate key or column in \(selection.table)")
            }
            guard Set(selection.key).isDisjoint(with: selection.columns) else {
                throw PostgresDiffError.invalidConfiguration(
                    "key columns are used for matching and must not be listed in columns: \(selection.table)"
                )
            }
            for name in [selection.table] + selection.key + selection.columns {
                guard !name.isEmpty, !name.contains("\0") else {
                    throw PostgresDiffError.invalidConfiguration("identifiers must not be empty or contain NUL")
                }
            }
            _ = try TableName(selection.table)
        }
    }
}

public struct PostgresColumnShape: Equatable, Sendable {
    public let name: String
    public let type: String
    public let nullable: Bool
    public let defaultValue: String?
    public let primaryKeyPosition: Int
}

public struct PostgresSchemaChange: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case added
        case removed
        case changed
    }

    public let object: String
    public let kind: Kind
    public let details: [String]
}

public struct PostgresSchemaDiff: Sendable {
    public let changes: [PostgresSchemaChange]
    public var isIdentical: Bool { changes.isEmpty }
}

public struct PostgresTableDataDiff: Equatable, Sendable {
    public let table: String
    public let added: Int
    public let removed: Int
    public let changed: Int
    public let changedColumns: [String]
}

public struct PostgresTableSkipped: Equatable, Sendable {
    public let table: String
    public let reason: String
}

public struct PostgresDiffResult: Sendable {
    public let schema: PostgresSchemaDiff?
    public let data: [PostgresTableDataDiff]
    public let skipped: [PostgresTableSkipped]
    public var isIdentical: Bool {
        (schema?.isIdentical ?? true)
            && data.allSatisfy { $0.added == 0 && $0.removed == 0 && $0.changed == 0 }
            && skipped.isEmpty
    }
    public var isIncomplete: Bool { !skipped.isEmpty }
    public var result: String {
        isIncomplete ? "incomplete" : (isIdentical ? "identical" : "differ")
    }
}

public enum PostgresDiffError: Error, CustomStringConvertible {
    case invalidConnection(String)
    case invalidConfiguration(String)
    case queryFailed(String)
    case rowLimitExceeded(String)

    public var description: String {
        switch self {
        case .invalidConnection(let reason): return t("error.postgres.invalid_connection", reason)
        case .invalidConfiguration(let reason): return t("error.postgres.invalid_configuration", reason)
        case .queryFailed(let reason): return t("error.postgres.query_failed", reason)
        case .rowLimitExceeded(let table): return t("error.postgres.row_limit_exceeded", table)
        }
    }
}

struct ConnectionSettings {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let database: String
    let tls: PostgresClient.Configuration.TLS
    let usesTLS: Bool

    init(url: String) throws {
        guard let components = URLComponents(string: url),
              ["postgres", "postgresql"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              let username = components.user, !username.isEmpty,
              components.path.count > 1 else {
            throw PostgresDiffError.invalidConnection("expected postgresql://user:password@host/database")
        }
        let query = Dictionary(
            components.queryItems?.map { ($0.name.lowercased(), $0.value ?? "") } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        guard query.keys.allSatisfy({ $0 == "sslmode" }) else {
            throw PostgresDiffError.invalidConnection("only the sslmode URL parameter is supported")
        }
        let sslMode = query["sslmode"] ?? "require"
        usesTLS = sslMode != "disable"
        switch sslMode {
        case "disable":
            tls = .disable
        case "require", "verify-ca", "verify-full":
            tls = .require(.makeClientConfiguration())
        default:
            throw PostgresDiffError.invalidConnection("unsupported sslmode: \(sslMode)")
        }
        self.host = host
        self.port = components.port ?? 5432
        guard (1...65_535).contains(self.port) else {
            throw PostgresDiffError.invalidConnection("port must be between 1 and 65535")
        }
        self.username = username
        self.password = components.password
        self.database = String(components.path.dropFirst())
    }

    var clientConfiguration: PostgresClient.Configuration {
        var configuration = PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: tls
        )
        configuration.options.maximumConnections = 1
        return configuration
    }
}

private struct TableName: Hashable, Sendable {
    let schema: String
    let name: String

    init(_ raw: String) throws {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            throw PostgresDiffError.invalidConfiguration("table names must use schema.table form: \(raw)")
        }
        schema = parts[0]
        name = parts[1]
    }

    var displayName: String { "\(schema).\(name)" }
    var quoted: String { "\(quoteIdentifier(schema)).\(quoteIdentifier(name))" }
}

struct DataRow: Sendable {
    let key: String
    let values: [String: String]
}

public enum PostgresDatabaseDiff {
    private static let maximumRowsPerTable = 10_000

    public static func compare(
        fromURL: String,
        toURL: String,
        mode: PostgresDiffMode,
        configuration: PostgresDiffConfiguration?
    ) async throws -> PostgresDiffResult {
        let fromSettings = try ConnectionSettings(url: fromURL)
        let toSettings = try ConnectionSettings(url: toURL)
        if mode != .schema {
            guard let configuration else {
                throw PostgresDiffError.invalidConfiguration("data and both modes require --config")
            }
            try configuration.validate()
        }

        let fromSchema = try await withReadOnlyConnection(fromSettings) { try await readSchema($0) }
        let toSchema = try await withReadOnlyConnection(toSettings) { try await readSchema($0) }
        let schemaDiff = mode == .data ? nil : compareSchemas(fromSchema, toSchema)
        guard mode != .schema, let configuration else {
            return PostgresDiffResult(schema: schemaDiff, data: [], skipped: [])
        }

        var dataDiffs: [PostgresTableDataDiff] = []
        var skipped: [PostgresTableSkipped] = []
        var comparableTables: [(TableName, PostgresTableSelection)] = []
        for selection in configuration.tables {
            let table = try TableName(selection.table)
            guard let leftColumns = fromSchema.tables[table.displayName],
                  let rightColumns = toSchema.tables[table.displayName] else {
                skipped.append(.init(table: table.displayName, reason: "table is missing on one side"))
                continue
            }
            if let reason = compatibilityIssue(selection, left: leftColumns, right: rightColumns) {
                skipped.append(.init(table: table.displayName, reason: reason))
                continue
            }
            comparableTables.append((table, selection))
        }
        let leftRows = try await readSelectedRows(fromSettings, tables: comparableTables)
        let rightRows = try await readSelectedRows(toSettings, tables: comparableTables)
        for (table, selection) in comparableTables {
            dataDiffs.append(compareRows(
                table: table.displayName,
                left: leftRows[table.displayName] ?? [],
                right: rightRows[table.displayName] ?? [],
                columns: selection.columns
            ))
        }
        return PostgresDiffResult(schema: schemaDiff, data: dataDiffs, skipped: skipped)
    }

    private static func readSelectedRows(
        _ settings: ConnectionSettings,
        tables: [(TableName, PostgresTableSelection)]
    ) async throws -> [String: [DataRow]] {
        try await withReadOnlyConnection(settings) { connection in
            var result: [String: [DataRow]] = [:]
            for (table, selection) in tables {
                result[table.displayName] = try await readRows(connection, table: table, selection: selection)
            }
            return result
        }
    }

    private static func withReadOnlyConnection<Value: Sendable>(
        _ settings: ConnectionSettings,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Value
    ) async throws -> Value {
        let client = PostgresClient(configuration: settings.clientConfiguration)
        return try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { await client.run() }
            do {
                let result = try await client.withConnection { connection in
                    _ = try await connection.query(
                        "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"
                    ).get()
                    do {
                        _ = try await connection.query("SET LOCAL TimeZone = 'UTC'").get()
                        _ = try await connection.query("SET LOCAL IntervalStyle = 'iso_8601'").get()
                        _ = try await connection.query("SET LOCAL extra_float_digits = 3").get()
                        let value = try await body(connection)
                        _ = try await connection.query("COMMIT").get()
                        return value
                    } catch {
                        _ = try? await connection.query("ROLLBACK").get()
                        throw error
                    }
                }
                tasks.cancelAll()
                return result
            } catch {
                tasks.cancelAll()
                throw error
            }
        }
    }

    private static func readRows(
        _ connection: PostgresConnection,
        table: TableName,
        selection: PostgresTableSelection
    ) async throws -> [DataRow] {
        let keys = selection.key.map { "row.\(quoteIdentifier($0))" }
        let values = selection.columns
            .map {
                "'\($0.replacingOccurrences(of: "'", with: "''"))', "
                    + "COALESCE(to_jsonb(row.\(quoteIdentifier($0)))::text, 'null')"
            }
        let query = """
            SELECT jsonb_build_array(\(keys.joined(separator: ", ")))::text,
                   jsonb_build_object(\(values.joined(separator: ", ")))::text
            FROM \(table.quoted) AS row
            ORDER BY \(keys.joined(separator: ", "))
            LIMIT \(maximumRowsPerTable + 1)
            """
        let queryResult = try await connection.query(query).get()
        var result: [DataRow] = []
        for row in queryResult {
            let (key, valuesJSON) = try row.decode((String, String).self)
            guard result.count < maximumRowsPerTable else {
                throw PostgresDiffError.rowLimitExceeded(table.displayName)
            }
            guard let object = try JSONSerialization.jsonObject(with: Data(valuesJSON.utf8)) as? [String: String] else {
                throw PostgresDiffError.queryFailed("could not decode row values for \(table.displayName)")
            }
            var canonicalValues: [String: String] = [:]
            for column in selection.columns {
                guard let value = object[column] else {
                    throw PostgresDiffError.queryFailed("query omitted column \(column)")
                }
                canonicalValues[column] = value
            }
            result.append(DataRow(key: key, values: canonicalValues))
        }
        return result
    }

    static func compareRows(
        table: String, left: [DataRow], right: [DataRow], columns: [String]
    ) -> PostgresTableDataDiff {
        let leftByKey = Dictionary(uniqueKeysWithValues: left.map { ($0.key, $0) })
        let rightByKey = Dictionary(uniqueKeysWithValues: right.map { ($0.key, $0) })
        let leftKeys = Set(leftByKey.keys)
        let rightKeys = Set(rightByKey.keys)
        let common = leftKeys.intersection(rightKeys)
        var changed = 0
        var changedColumns = Set<String>()
        for key in common {
            guard let before = leftByKey[key], let after = rightByKey[key] else { continue }
            let columnsChanged = columns.filter { before.values[$0] != after.values[$0] }
            if !columnsChanged.isEmpty {
                changed += 1
                changedColumns.formUnion(columnsChanged)
            }
        }
        return PostgresTableDataDiff(
            table: table,
            added: rightKeys.subtracting(leftKeys).count,
            removed: leftKeys.subtracting(rightKeys).count,
            changed: changed,
            changedColumns: changedColumns.sorted()
        )
    }
}

func quoteIdentifier(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}
