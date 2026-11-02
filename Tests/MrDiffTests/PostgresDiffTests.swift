import XCTest
import MrDiffCore
@testable import MrDiffPostgres
@testable import mrdiff

final class PostgresConfigurationTests: XCTestCase {
    func testConfigurationAcceptsConfiguredTableKeyAndColumns() throws {
        let configuration = try JSONDecoder().decode(
            PostgresDiffConfiguration.self,
            from: Data(
                #"""
                {"tables":[{"table":"public.countries","key":["id"],"columns":["name","code"]}]}
                """#.utf8
            )
        )

        XCTAssertNoThrow(try configuration.validate())
        XCTAssertEqual(configuration.tables.first?.table, "public.countries")
    }

    func testConfigurationReadWrapsMissingAndMalformedFiles() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrdiff-missing-\(UUID().uuidString).json")
        XCTAssertThrowsError(try PostgresDiffConfiguration.read(from: missingURL)) { error in
            guard case PostgresDiffError.invalidConfiguration = error else {
                return XCTFail("unexpected missing-file error: \(error)")
            }
        }

        let malformedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrdiff-malformed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: malformedURL) }
        try Data(#"{"tables":"#.utf8).write(to: malformedURL)
        XCTAssertThrowsError(try PostgresDiffConfiguration.read(from: malformedURL)) { error in
            guard case PostgresDiffError.invalidConfiguration = error else {
                return XCTFail("unexpected malformed-JSON error: \(error)")
            }
        }
    }

    func testConfigurationRejectsDuplicateTables() throws {
        let configuration = try JSONDecoder().decode(
            PostgresDiffConfiguration.self,
            from: Data(
                #"""
                {"tables":[{"table":"public.items","key":["id"],"columns":["name"]},
                 {"table":"public.items","key":["id"],"columns":["name"]}]}
                """#.utf8
            )
        )

        assertInvalidConfiguration(configuration, reason: "duplicate table")
    }

    func testConfigurationRejectsComparingKeyColumnsAsData() throws {
        let configuration = try JSONDecoder().decode(
            PostgresDiffConfiguration.self,
            from: Data(#"{"tables":[{"table":"public.items","key":["id"],"columns":["id","name"]}]}"#.utf8)
        )

        assertInvalidConfiguration(configuration, reason: "key columns are used for matching")
    }

    func testConfigurationRequiresSchemaQualifiedTableNames() throws {
        let configuration = try JSONDecoder().decode(
            PostgresDiffConfiguration.self,
            from: Data(#"{"tables":[{"table":"items","key":["id"],"columns":["name"]}]}"#.utf8)
        )

        assertInvalidConfiguration(configuration, reason: "schema.table")
    }

    func testConfigurationValidationReportsEmptyTablesAndKeys() {
        assertInvalidConfiguration(.init(tables: []), reason: "tables must not be empty")
        assertInvalidConfiguration(
            .init(tables: [.init(table: "public.items", key: [], columns: ["name"])]),
            reason: "each table needs"
        )
    }

    func testConfigurationValidationReportsDuplicateColumnsAndInvalidNames() {
        assertInvalidConfiguration(
            .init(tables: [.init(table: "public.items", key: ["id"], columns: ["name", "name"])]),
            reason: "duplicate key or column"
        )
        assertInvalidConfiguration(
            .init(tables: [.init(table: "a.b.c", key: ["id"], columns: ["name"])]),
            reason: "schema.table"
        )
        assertInvalidConfiguration(
            .init(tables: [.init(table: "public.items", key: ["id"], columns: ["na\0me"])]),
            reason: "must not be empty or contain NUL"
        )
    }

    private func assertInvalidConfiguration(
        _ configuration: PostgresDiffConfiguration,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try configuration.validate()
            XCTFail("expected invalid configuration containing '\(reason)'", file: file, line: line)
        } catch let error as PostgresDiffError {
            guard case .invalidConfiguration(let actualReason) = error else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(actualReason.contains(reason), actualReason, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

final class PostgresDiffTests: XCTestCase {
    func testConnectionSettingsRequirePostgresAndTLSByDefault() throws {
        XCTAssertTrue(try ConnectionSettings(url: "postgresql://u@h/db").usesTLS)
        XCTAssertFalse(try ConnectionSettings(url: "postgresql://u@h/db?sslmode=disable").usesTLS)
    }

    func testConnectionSettingsRejectInvalidSchemesAndTLSOptions() {
        for url in [
            "postgresql://u@h/db?sslmode=prefer",
            "postgresql://u@h/db?foo=1",
            "mysql://u@h/db",
            "postgresql://h/db",
            "postgresql://u@h"
        ] {
            XCTAssertThrowsError(try ConnectionSettings(url: url), url) { error in
                guard case PostgresDiffError.invalidConnection = error else {
                    return XCTFail("unexpected error for \(url): \(error)")
                }
            }
        }
    }

    func testConnectionSettingsDecodeCredentialsOnlyOnce() throws {
        XCTAssertEqual(
            try ConnectionSettings(url: "postgresql://u:p%25ss@h/db").password,
            "p%ss"
        )
        XCTAssertEqual(
            try ConnectionSettings(url: "postgresql://u:p%2541@h/db").password,
            "p%41"
        )
    }

    func testCompatibilityIssueRejectsMismatchedKeysTypesAndMissingColumns() {
        let selection = PostgresTableSelection(table: "public.items", key: ["id"], columns: ["name"])
        let left = [
            "id": column("id", type: "integer", keyPosition: 1),
            "lang": column("lang", type: "text", keyPosition: 2),
            "name": column("name", type: "text")
        ]
        let compositeKey = left
        XCTAssertEqual(
            PostgresDatabaseDiff.compatibilityIssue(selection, left: compositeKey, right: compositeKey),
            "configured key must match the primary key on both sides"
        )

        let reorderedRight = [
            "id": column("id", type: "integer", keyPosition: 2),
            "lang": column("lang", type: "text", keyPosition: 1),
            "name": column("name", type: "text")
        ]
        XCTAssertEqual(
            PostgresDatabaseDiff.compatibilityIssue(selection, left: reorderedRight, right: compositeKey),
            "configured key must match the primary key on both sides"
        )

        let configuredKey = ["id": left["id"]!, "name": left["name"]!]
        let differentType = ["id": left["id"]!, "name": column("name", type: "varchar(10)")]
        XCTAssertEqual(
            PostgresDatabaseDiff.compatibilityIssue(selection, left: configuredKey, right: differentType),
            "column type differs for name"
        )
        XCTAssertEqual(
            PostgresDatabaseDiff.compatibilityIssue(
                selection,
                left: configuredKey,
                right: ["id": left["id"]!]
            ),
            "a configured key or comparison column is missing"
        )
        XCTAssertNil(
            PostgresDatabaseDiff.compatibilityIssue(selection, left: configuredKey, right: configuredKey)
        )
    }

    func testCompareRowsDistinguishesNullFromStringNullAndSupportsCompositeKeys() {
        let diff = PostgresDatabaseDiff.compareRows(
            table: "public.items",
            left: [.init(key: #"["1","en"]"#, values: ["name": "null"])],
            right: [.init(key: #"["1","en"]"#, values: ["name": #""null""#])],
            columns: ["name"]
        )

        XCTAssertEqual(diff.changed, 1)
        XCTAssertEqual(diff.changedColumns, ["name"])
        XCTAssertEqual(diff.added, 0)
        XCTAssertEqual(diff.removed, 0)
    }

    func testCompareRowsCountsUnmatchedKeysAndEmptyInputs() {
        let unmatched = PostgresDatabaseDiff.compareRows(
            table: "public.items",
            left: [.init(key: #"["1","en"]"#, values: [:])],
            right: [.init(key: #"["2","fr"]"#, values: [:])],
            columns: []
        )
        XCTAssertEqual(unmatched.added, 1)
        XCTAssertEqual(unmatched.removed, 1)

        let empty = PostgresDatabaseDiff.compareRows(table: "public.items", left: [], right: [], columns: [])
        XCTAssertEqual(empty.added, 0)
        XCTAssertEqual(empty.removed, 0)
        XCTAssertEqual(empty.changed, 0)
        XCTAssertTrue(empty.changedColumns.isEmpty)
    }

    func testQuoteIdentifierEscapesEmbeddedDoubleQuotes() {
        XCTAssertEqual(quoteIdentifier("a\"b"), "\"a\"\"b\"")
    }

    func testSchemaComparisonReportsColumnAndIndexDefinitionChanges() {
        let left = PostgresSchema(
            tables: ["public.items": ["name": column("name", type: "text", nullable: true)]],
            constraints: [:],
            indexes: ["public.items.items_name_idx": "CREATE INDEX ... (name)"]
        )
        let right = PostgresSchema(
            tables: ["public.items": ["name": column("name", type: "text", nullable: false)]],
            constraints: [:],
            indexes: ["public.items.items_name_idx": "CREATE INDEX ... (lower(name))"]
        )

        let changes = PostgresDatabaseDiff.compareSchemas(left, right).changes
        XCTAssertTrue(changes.contains {
            $0.object == "public.items.name"
                && $0.kind == .changed
                && $0.details.contains("nullable: true -> false")
        })
        XCTAssertTrue(changes.contains {
            $0.object == "public.items.items_name_idx"
                && $0.kind == .changed
                && $0.details.contains("definition changed")
        })
    }

    func testIncompleteCommandOutputIncludesSkippedResults() throws {
        let result = PostgresDiffResult(
            schema: nil,
            data: [],
            skipped: [.init(table: "public.items", reason: "missing on one side")]
        )
        let json = try PostgresDiffCommand.encodeJSON(result, mode: .data)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["result"] as? String, "incomplete")
        let skipped = try XCTUnwrap(object["skipped"] as? [[String: String]])
        XCTAssertEqual(skipped.first?["table"], "public.items")
        XCTAssertEqual(skipped.first?["reason"], "missing on one side")
        XCTAssertTrue(PostgresDiffCommand.render(result, mode: .data).contains(t("postgres.incomplete")))
    }

    func testCommandOptionsParseModesAndRejectInvalidArguments() throws {
        XCTAssertEqual(try PostgresCommandOptions.parse(["--mode=both"]).mode, .both)
        assertInvalidConfiguration {
            _ = try PostgresCommandOptions.parse(["--config"])
        }
        assertInvalidConfiguration {
            _ = try PostgresCommandOptions.parse(["--mode", "all"])
        }
        assertInvalidConfiguration {
            _ = try PostgresCommandOptions.parse(["--foo"])
        }
    }

    func testCommandRejectsSameEnvironmentNameAndEmptyEnvironmentValues() {
        assertInvalidConfiguration {
            _ = try PostgresDiffCommand.run(
                arguments: ["--from-env", "X", "--to-env", "X", "--mode", "schema"],
                environment: [:],
                json: false
            )
        }
        XCTAssertThrowsError(
            try PostgresDiffCommand.run(
                arguments: ["--from-env", "FROM", "--to-env", "TO", "--mode", "schema"],
                environment: ["FROM": "", "TO": "postgresql://u@h/db"],
                json: false
            )
        ) { error in
            guard case PostgresDiffError.invalidConnection = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

    }

    func testSkippedTablesMakeTheComparisonIncomplete() {
        let result = PostgresDiffResult(
            schema: nil,
            data: [],
            skipped: [.init(table: "public.items", reason: "missing primary key")]
        )

        XCTAssertTrue(result.isIncomplete)
        XCTAssertFalse(result.isIdentical)
        XCTAssertEqual(result.result, "incomplete")
    }

    func testDataModesRequireAConfigBeforeOpeningConnections() async {
        do {
            _ = try await PostgresDatabaseDiff.compare(
                fromURL: "postgresql://user@localhost/db?sslmode=disable",
                toURL: "postgresql://user@localhost/db?sslmode=disable",
                mode: .data,
                configuration: nil
            )
            XCTFail("expected missing config to be rejected")
        } catch let error as PostgresDiffError {
            guard case .invalidConfiguration = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func column(
        _ name: String,
        type: String,
        nullable: Bool = false,
        keyPosition: Int = 0
    ) -> PostgresColumnShape {
        PostgresColumnShape(
            name: name,
            type: type,
            nullable: nullable,
            defaultValue: nil,
            primaryKeyPosition: keyPosition
        )
    }

    private func assertInvalidConfiguration(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case PostgresDiffError.invalidConfiguration = error else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
        }
    }
}
