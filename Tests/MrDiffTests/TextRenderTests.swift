import XCTest

final class TextRenderTests: XCTestCase {
    func testMovedBlocksRenderOneBasedNotesBeforeEachBlock() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = try XCTUnwrap(mrdiffExecutable(from: packageRoot), "mrdiff executable was not built")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrdiff-move-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = directory.appendingPathComponent("before.txt")
        let after = directory.appendingPathComponent("after.txt")
        let moved = ["func moved() {", "    save()", "}"]
        let stationary = ["one", "two", "three", "four", "five"]
        try (["start"] + moved + stationary + ["end"]).joined(separator: "\n").write(
            to: before, atomically: true, encoding: .utf8
        )
        try (["start"] + stationary + moved + ["end"]).joined(separator: "\n").write(
            to: after, atomically: true, encoding: .utf8
        )

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--no-pager", "--color=never", "--lang=en", before.path, after.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let rendered = try XCTUnwrap(
            String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        )
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let lines = rendered.components(separatedBy: .newlines)
        let deletedBlockNote = try XCTUnwrap(
            lines.firstIndex(of: "    ### moved to line 7 ###"), rendered
        )
        let addedBlockNote = try XCTUnwrap(
            lines.firstIndex(of: "    ### moved from line 2 ###"), rendered
        )
        XCTAssertTrue(lines[deletedBlockNote + 1].contains("- func moved() {"))
        XCTAssertTrue(lines[addedBlockNote + 1].contains("+ func moved() {"))
    }

    private func mrdiffExecutable(from packageRoot: URL) -> URL? {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = ""
        #endif
        let candidates = [
            packageRoot.appendingPathComponent(".build/out/Products/Debug/mrdiff"),
            packageRoot.appendingPathComponent(".build/\(architecture)-apple-macosx/debug/mrdiff"),
            packageRoot.appendingPathComponent(".build/debug/mrdiff")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
