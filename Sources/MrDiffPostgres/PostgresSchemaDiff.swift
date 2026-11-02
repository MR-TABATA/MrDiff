import PostgresNIO

struct PostgresSchema: Sendable {
    var tables: [String: [String: PostgresColumnShape]]
    var constraints: [String: String]
    var indexes: [String: String]
}

extension PostgresDatabaseDiff {
    static func readSchema(_ connection: PostgresConnection) async throws -> PostgresSchema {
        PostgresSchema(
            tables: try await readColumns(connection),
            constraints: try await readConstraints(connection),
            indexes: try await readIndexes(connection)
        )
    }

    static func compareSchemas(_ left: PostgresSchema, _ right: PostgresSchema) -> PostgresSchemaDiff {
        var changes: [PostgresSchemaChange] = []
        for table in Set(left.tables.keys).union(right.tables.keys).sorted() {
            guard let leftColumns = left.tables[table] else {
                changes.append(.init(object: table, kind: .added, details: []))
                continue
            }
            guard let rightColumns = right.tables[table] else {
                changes.append(.init(object: table, kind: .removed, details: []))
                continue
            }
            for columnName in Set(leftColumns.keys).union(rightColumns.keys).sorted() {
                let objectName = "\(table).\(columnName)"
                guard let leftColumn = leftColumns[columnName] else {
                    changes.append(.init(object: objectName, kind: .added, details: []))
                    continue
                }
                guard let rightColumn = rightColumns[columnName] else {
                    changes.append(.init(object: objectName, kind: .removed, details: []))
                    continue
                }
                let details = columnChanges(leftColumn, rightColumn)
                if !details.isEmpty {
                    changes.append(.init(object: objectName, kind: .changed, details: details))
                }
            }
        }
        changes += compareObjects(left.constraints, right.constraints)
        changes += compareObjects(left.indexes, right.indexes)
        return PostgresSchemaDiff(changes: changes)
    }

    static func compatibilityIssue(
        _ selection: PostgresTableSelection,
        left: [String: PostgresColumnShape],
        right: [String: PostgresColumnShape]
    ) -> String? {
        guard selection.key.allSatisfy({ left[$0] != nil && right[$0] != nil }),
              selection.columns.allSatisfy({ left[$0] != nil && right[$0] != nil }) else {
            return "a configured key or comparison column is missing"
        }
        let leftKey = left.values.filter { $0.primaryKeyPosition > 0 }
            .sorted { $0.primaryKeyPosition < $1.primaryKeyPosition }.map(\.name)
        let rightKey = right.values.filter { $0.primaryKeyPosition > 0 }
            .sorted { $0.primaryKeyPosition < $1.primaryKeyPosition }.map(\.name)
        guard leftKey == selection.key, rightKey == selection.key else {
            return "configured key must match the primary key on both sides"
        }
        for name in selection.key + selection.columns {
            guard left[name]?.type == right[name]?.type else {
                return "column type differs for \(name)"
            }
        }
        return nil
    }

    private static func readColumns(
        _ connection: PostgresConnection
    ) async throws -> [String: [String: PostgresColumnShape]] {
        let rows = try await connection.query("""
            SELECT namespace.nspname, relation.relname, attribute.attname,
                   pg_catalog.format_type(attribute.atttypid, attribute.atttypmod),
                   attribute.attnotnull::text, pg_catalog.pg_get_expr(default_value.adbin, default_value.adrelid),
                   COALESCE(primary_key.ordinality, 0)::text
            FROM pg_catalog.pg_class AS relation
            JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            JOIN pg_catalog.pg_attribute AS attribute ON attribute.attrelid = relation.oid
            LEFT JOIN pg_catalog.pg_attrdef AS default_value
              ON default_value.adrelid = relation.oid AND default_value.adnum = attribute.attnum
            LEFT JOIN LATERAL (
                SELECT key_column.ordinality
                FROM pg_catalog.pg_constraint AS constraint_row
                CROSS JOIN LATERAL unnest(constraint_row.conkey) WITH ORDINALITY AS key_column(attnum, ordinality)
                WHERE constraint_row.conrelid = relation.oid
                  AND constraint_row.contype = 'p'
                  AND key_column.attnum = attribute.attnum
            ) AS primary_key ON true
            WHERE relation.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND attribute.attnum > 0 AND NOT attribute.attisdropped
              AND namespace.nspname <> 'information_schema'
              AND namespace.nspname NOT LIKE 'pg!_%' ESCAPE '!'
            ORDER BY namespace.nspname, relation.relname, attribute.attnum
            """).get()
        var tables: [String: [String: PostgresColumnShape]] = [:]
        for row in rows {
            let (
                schema, table, column, type, notNull, defaultValue, primaryKeyPosition
            ) = try row.decode((String, String, String, String, String, String?, String).self)
            let shape = PostgresColumnShape(
                name: column,
                type: type,
                nullable: notNull != "true",
                defaultValue: defaultValue,
                primaryKeyPosition: Int(primaryKeyPosition) ?? 0
            )
            tables["\(schema).\(table)", default: [:]][column] = shape
        }
        return tables
    }

    private static func readConstraints(_ connection: PostgresConnection) async throws -> [String: String] {
        let rows = try await connection.query("""
            SELECT namespace.nspname, relation.relname, constraint_row.conname,
                   pg_catalog.pg_get_constraintdef(constraint_row.oid, true)
            FROM pg_catalog.pg_constraint AS constraint_row
            JOIN pg_catalog.pg_class AS relation ON relation.oid = constraint_row.conrelid
            JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
            WHERE namespace.nspname <> 'information_schema'
              AND namespace.nspname NOT LIKE 'pg!_%' ESCAPE '!'
            ORDER BY namespace.nspname, relation.relname, constraint_row.conname
            """).get()
        var constraints: [String: String] = [:]
        for row in rows {
            let (schema, table, name, definition) = try row.decode((String, String, String, String).self)
            constraints["\(schema).\(table).\(name)"] = definition
        }
        return constraints
    }

    private static func readIndexes(_ connection: PostgresConnection) async throws -> [String: String] {
        let rows = try await connection.query("""
            SELECT schemaname, tablename, indexname, indexdef
            FROM pg_catalog.pg_indexes
            WHERE schemaname <> 'information_schema'
              AND schemaname NOT LIKE 'pg!_%' ESCAPE '!'
            ORDER BY schemaname, tablename, indexname
            """).get()
        var indexes: [String: String] = [:]
        for row in rows {
            let (schema, table, name, definition) = try row.decode((String, String, String, String).self)
            indexes["\(schema).\(table).\(name)"] = definition
        }
        return indexes
    }

    private static func compareObjects(
        _ left: [String: String], _ right: [String: String]
    ) -> [PostgresSchemaChange] {
        var changes: [PostgresSchemaChange] = []
        for object in Set(left.keys).union(right.keys).sorted() {
            guard let leftDefinition = left[object] else {
                changes.append(.init(object: object, kind: .added, details: []))
                continue
            }
            guard let rightDefinition = right[object] else {
                changes.append(.init(object: object, kind: .removed, details: []))
                continue
            }
            if leftDefinition != rightDefinition {
                changes.append(.init(object: object, kind: .changed, details: ["definition changed"]))
            }
        }
        return changes
    }

    private static func columnChanges(_ left: PostgresColumnShape, _ right: PostgresColumnShape) -> [String] {
        var details: [String] = []
        if left.type != right.type { details.append("type: \(left.type) -> \(right.type)") }
        if left.nullable != right.nullable {
            details.append("nullable: \(left.nullable) -> \(right.nullable)")
        }
        if left.defaultValue != right.defaultValue {
            details.append("default expression changed")
        }
        if left.primaryKeyPosition != right.primaryKeyPosition {
            details.append("primary key position: \(left.primaryKeyPosition) -> \(right.primaryKeyPosition)")
        }
        return details
    }
}
