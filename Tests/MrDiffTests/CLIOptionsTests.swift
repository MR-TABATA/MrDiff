import XCTest
@testable import MrDiffCore

/// つまみの表（`--help` と補完が共有）、シェル補完、`--relative` のパス表示の試験。
final class CLIOptionsTests: XCTestCase {

    // MARK: - 表

    /// **どのつまみにも、日英の説明がある。** 訳が抜けると、キー名がそのまま画面に出る。
    func testEveryOptionHasAHelpTextInBothLanguages() {
        for lang in ["en", "ja"] {
            Lang.select(lang)
            for o in CLIOptions.all {
                XCTAssertNotEqual(t(o.helpKey), o.helpKey, "\(lang): \(o.helpKey) の訳が無い")
            }
        }
        Lang.select("en")
    }

    func testNoWordIsListedTwice() {
        let words = CLIOptions.all.flatMap(\.words)
        XCTAssertEqual(words.count, Set(words).count)
    }

    // MARK: - 補完スクリプト

    func testEveryShellScriptMentionsEveryOption() throws {
        for shell in Completions.shells {
            let script = try XCTUnwrap(Completions.script(for: shell), shell)
            for w in CLIOptions.all.flatMap(\.words) {
                let bare = w.hasSuffix("=") ? String(w.dropLast()) : w
                // fish は `-l name` / `-s x` の形で、他は `--name` のまま
                let needle = shell == "fish"
                    ? (bare.hasPrefix("--") ? "-l \(bare.dropFirst(2))" : "-s \(bare.dropFirst(1))")
                    : bare
                XCTAssertTrue(script.contains(needle), "\(shell): \(w) が補完に無い")
            }
        }
    }

    func testUnknownShellHasNoScript() {
        XCTAssertNil(Completions.script(for: "powershell"))
        XCTAssertNil(Completions.script(for: ""))
    }

    func testDescriptionsFollowTheLanguage() throws {
        Lang.select("ja")
        defer { Lang.select("en") }
        let zsh = try XCTUnwrap(Completions.script(for: "zsh"))
        XCTAssertTrue(zsh.contains("何も出さず"))
    }

    /// 作ったスクリプトを、実際のシェルに読ませる（構文が壊れていないこと）。
    func testBashAndZshAcceptTheirScripts() throws {
        for (shell, path) in [("bash", "/bin/bash"), ("zsh", "/bin/zsh")] {
            guard FileManager.default.isExecutableFile(atPath: path) else { throw XCTSkip("\(path) が無い") }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("mrdiff-comp-\(UUID().uuidString).\(shell)")
            try XCTUnwrap(Completions.script(for: shell)).write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-n", file.path]
            let err = Pipe(); p.standardError = err
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(shell) -n: " + String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    /// bash の補完を、本当に動かす。`--color=` の値、`=` で分かれた語、フラグ、ファイル名。
    func testBashCompletionReallyCompletes() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/bash") else { throw XCTSkip("bash が無い") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mrdiff-bash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        let comp = dir.appendingPathComponent("comp.bash")
        try XCTUnwrap(Completions.script(for: "bash")).write(to: comp, atomically: true, encoding: .utf8)
        let driver = """
        source "\(comp.path)"
        cd "\(dir.path)"
        t() { COMP_WORDS=("$@"); COMP_CWORD=$((${#COMP_WORDS[@]}-1)); COMPREPLY=(); _mrdiff; echo "$*|${COMPREPLY[*]}"; }
        t mrdiff --colo
        t mrdiff --color =
        t mrdiff --color=
        t mrdiff --color=al
        t mrdiff --color = a
        t mrdiff --completions ""
        t mrdiff --lang = j
        t mrdiff no
        """
        let script = dir.appendingPathComponent("drive.sh")
        try driver.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [
            "mrdiff --colo|--color=",
            "mrdiff --color =|auto always never",
            "mrdiff --color=|--color=auto --color=always --color=never",
            "mrdiff --color=al|--color=always",
            "mrdiff --color = a|auto always",
            "mrdiff --completions |bash zsh fish",
            "mrdiff --lang = j|ja",
            "mrdiff no|notes.txt",
        ])
    }

    // MARK: - --relative

    func testRelativePathsInsideTheCurrentDirectoryAreShortened() {
        XCTAssertEqual(PathDisplay.relative("/work/repo/a/b.png", to: "/work/repo"), "a/b.png")
        XCTAssertEqual(PathDisplay.relative("/work/repo/a.png", to: "/work/repo/"), "a.png")
        XCTAssertEqual(PathDisplay.relative("/work/repo", to: "/work/repo"), ".")
    }

    /// 外のパスや、前方一致だけの別の名前（`/work/repo2`）は、そのまま。`../` は使わない。
    func testPathsOutsideAreLeftAlone() {
        XCTAssertEqual(PathDisplay.relative("/etc/hosts", to: "/work/repo"), "/etc/hosts")
        XCTAssertEqual(PathDisplay.relative("/work/repo2/a.png", to: "/work/repo"), "/work/repo2/a.png")
    }

    func testDefaultIsStillTheFullPath() {
        PathDisplay.relativeToCurrentDirectory = false
        XCTAssertEqual(PathDisplay.text(URL(fileURLWithPath: "/tmp/x.png")), "/tmp/x.png")
    }
}
