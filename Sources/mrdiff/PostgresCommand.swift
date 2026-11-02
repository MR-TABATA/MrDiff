import Foundation
import MrDiffCore
import MrDiffPostgres

struct PostgresCommandResult {
    let output: String
    let exitCode: Int32
}

enum PostgresDiffCommand {
    static func run(
        arguments: [String],
        environment: [String: String],
        json: Bool
    ) throws -> PostgresCommandResult {
        let options = try PostgresCommandOptions.parse(arguments)
        guard let fromEnvironment = options.fromEnvironment,
              let toEnvironment = options.toEnvironment,
              let mode = options.mode else {
            throw PostgresDiffError.invalidConfiguration(
                "usage: mrdiff db --from-env NAME --to-env NAME --mode schema|data|both [--config FILE]"
            )
        }
        guard fromEnvironment != toEnvironment else {
            throw PostgresDiffError.invalidConfiguration("the source and destination environment variables must differ")
        }
        guard let fromURL = environment[fromEnvironment], !fromURL.isEmpty else {
            throw PostgresDiffError.invalidConnection("environment variable \(fromEnvironment) is unset")
        }
        guard let toURL = environment[toEnvironment], !toURL.isEmpty else {
            throw PostgresDiffError.invalidConnection("environment variable \(toEnvironment) is unset")
        }

        let configuration = try options.configPath.map {
            try PostgresDiffConfiguration.read(from: URL(fileURLWithPath: $0))
        }
        let result = try blockOnAsync {
            try await PostgresDatabaseDiff.compare(
                fromURL: fromURL, toURL: toURL, mode: mode, configuration: configuration
            )
        }
        let output = try json ? encodeJSON(result, mode: mode) : render(result, mode: mode)
        let exitCode: Int32 = result.isIncomplete ? 2 : (result.isIdentical ? 0 : 1)
        return PostgresCommandResult(output: output, exitCode: exitCode)
    }

    static func render(_ result: PostgresDiffResult, mode: PostgresDiffMode) -> String {
        var lines = [t("postgres.title", mode.rawValue)]
        if let schema = result.schema {
            let schemaResult = t(schema.isIdentical ? "postgres.schema.identical" : "postgres.schema.differ")
            lines.append(t("postgres.schema", schemaResult))
            for change in schema.changes {
                let details = change.details.map(\.terminalSafe)
                let detailText = details.isEmpty ? "" : " — " + details.joined(separator: ", ")
                lines.append(
                    "  \(t("postgres.kind.\(change.kind.rawValue)")) \(change.object.terminalSafe)\(detailText)"
                )
            }
        }
        if !result.data.isEmpty || !result.skipped.isEmpty {
            lines.append(t("postgres.data"))
            for diff in result.data {
                lines.append(
                    "  " + t("postgres.row_counts", diff.table.terminalSafe, diff.added, diff.removed, diff.changed)
                )
                if !diff.changedColumns.isEmpty {
                    let columns = diff.changedColumns.map(\.terminalSafe).joined(separator: ", ")
                    lines.append("    " + t("postgres.changed_columns", columns))
                }
            }
            for skipped in result.skipped {
                lines.append(
                    "  " + t("postgres.skipped", skipped.table.terminalSafe, skipped.reason.terminalSafe)
                )
            }
        }
        if result.isIncomplete {
            lines.append(t("postgres.incomplete"))
        }
        if result.isIdentical {
            lines.append(t("postgres.no_differences"))
        }
        return lines.joined(separator: "\n")
    }

    static func encodeJSON(_ result: PostgresDiffResult, mode: PostgresDiffMode) throws -> String {
        var output: [String: Any] = [
            "kind": "postgres",
            "mode": mode.rawValue,
            "result": result.result
        ]
        if let schema = result.schema {
            output["schema"] = [
                "result": schema.isIdentical ? "identical" : "differ",
                "changes": schema.changes.map {
                    ["object": $0.object, "status": $0.kind.rawValue, "details": $0.details] as [String: Any]
                    }
            ] as [String: Any]
        }
        if !result.data.isEmpty {
            output["data"] = result.data.map {
                [
                    "table": $0.table,
                    "added": $0.added,
                    "removed": $0.removed,
                    "changed": $0.changed,
                    "changed_columns": $0.changedColumns
                ] as [String: Any]
            }
        }
        if !result.skipped.isEmpty {
            output["skipped"] = result.skipped.map { ["table": $0.table, "reason": $0.reason] }
        }
        guard JSONSerialization.isValidJSONObject(output) else {
            throw PostgresDiffError.queryFailed("internal result is not valid JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .fragmentsAllowed])
        guard let encodedOutput = String(bytes: data, encoding: .utf8) else {
            throw PostgresDiffError.queryFailed("could not encode JSON output as UTF-8")
        }
        return encodedOutput
    }
}

struct PostgresCommandOptions {
    var fromEnvironment: String?
    var toEnvironment: String?
    var mode: PostgresDiffMode?
    var configPath: String?

    private struct ParsedArgument {
        let option: String
        let value: String
        let consumed: Int
    }

    static func parse(_ arguments: [String]) throws -> Self {
        var options = Self()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if ["--json", "--format=json", "--exit-code", "--quiet", "-q"].contains(argument)
                || argument.hasPrefix("--lang=") {
                index += 1
                continue
            }
            let parsed: ParsedArgument
            if ["--from-env", "--to-env", "--mode", "--config"].contains(argument) {
                guard index + 1 < arguments.count else {
                    throw PostgresDiffError.invalidConfiguration("\(argument) requires a value")
                }
                parsed = ParsedArgument(option: argument, value: arguments[index + 1], consumed: 2)
            } else {
                guard let inline = parseInline(argument) else {
                    throw PostgresDiffError.invalidConfiguration("unknown PostgreSQL option: \(argument)")
                }
                parsed = ParsedArgument(option: inline.0, value: inline.1, consumed: 1)
            }
            try options.set(parsed.option, value: parsed.value)
            index += parsed.consumed
        }
        return options
    }

    private mutating func set(_ option: String, value: String) throws {
        switch option {
        case "--from-env": fromEnvironment = value
        case "--to-env": toEnvironment = value
        case "--config": configPath = value
        case "--mode":
            guard let parsedMode = PostgresDiffMode(rawValue: value) else {
                throw PostgresDiffError.invalidConfiguration("--mode must be schema, data, or both")
            }
            mode = parsedMode
        default: throw PostgresDiffError.invalidConfiguration("unknown PostgreSQL option: \(option)")
        }
    }

    private static func parseInline(_ argument: String) -> (String, String)? {
        for option in ["--from-env", "--to-env", "--mode", "--config"] {
            if let value = argument.value(after: option + "=") {
                return (option, value)
            }
        }
        return nil
    }
}

private func blockOnAsync<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let box = AsyncResultBox<Value>()
    Task {
        do {
            box.complete(.success(try await operation()))
        } catch {
            box.complete(.failure(error))
        }
    }
    return try box.wait()
}

private final class AsyncResultBox<Value: Sendable>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws -> Value {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        guard let result else {
            throw PostgresDiffError.queryFailed("PostgreSQL operation completed without a result")
        }
        return try result.get()
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    var terminalSafe: String {
        String(unicodeScalars.map { scalar in
            guard scalar.properties.generalCategory == .control else { return String(scalar) }
            return "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        }.joined())
    }
}
