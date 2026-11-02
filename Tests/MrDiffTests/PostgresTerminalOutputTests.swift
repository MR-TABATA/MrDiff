import XCTest
@testable import MrDiffPostgres
@testable import mrdiff

final class PostgresTerminalOutputTests: XCTestCase {
    func testHumanOutputEscapesDatabaseControlCharacters() {
        let result = PostgresDiffResult(
            schema: .init(changes: [
                .init(
                    object: "public.items\u{1B}[31m",
                    kind: .changed,
                    details: ["type contains\u{07}bell"]
                )
            ]),
            data: [
                .init(
                    table: "public.items\u{1B}]52;c;payload\u{07}",
                    added: 0,
                    removed: 0,
                    changed: 1,
                    changedColumns: ["na\u{1B}me"]
                )
            ],
            skipped: [.init(table: "public.bad\u{1B}", reason: "reason\u{07}")]
        )

        let output = PostgresDiffCommand.render(result, mode: .both)
        XCTAssertFalse(
            output.unicodeScalars.contains {
                $0.properties.generalCategory == .control && $0 != "\n"
            }
        )
        XCTAssertTrue(output.contains(#"\u{1B}[31m"#))
        XCTAssertTrue(output.contains(#"\u{7}bell"#))
        XCTAssertTrue(output.contains(#"\u{1B}]52;c;payload\u{7}"#))
        XCTAssertTrue(output.contains(#"na\u{1B}me"#))
        XCTAssertTrue(output.contains(#"reason\u{7}"#))
    }
}
