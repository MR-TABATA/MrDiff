import XCTest
@testable import MrDiffCore

/// Homebrew は `bin/mrdiff` を `libexec/mrdiff` へのリンクにして、バンドルは libexec にだけ置く。
/// 0.9.0 はこの配置で、バンドルを見つけられず落ちた（ツールチェーンによる）。
final class ResourceBundleLocationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrdiff-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeLayout(withBundle: Bool) throws -> (link: URL, bundle: URL) {
        let fm = FileManager.default
        let libexec = root.appendingPathComponent("libexec")
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: libexec, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let exe = libexec.appendingPathComponent("mrdiff")
        fm.createFile(atPath: exe.path, contents: Data())
        let bundle = libexec.appendingPathComponent(Lang.resourceBundleName)
        if withBundle { try fm.createDirectory(at: bundle, withIntermediateDirectories: true) }
        let link = bin.appendingPathComponent("mrdiff")
        try fm.createSymbolicLink(at: link, withDestinationURL: exe)
        return (link, bundle)
    }

    func test_リンク経由でも実体の隣のバンドルを見つける() throws {
        let (link, bundle) = try makeLayout(withBundle: true)
        let found = try XCTUnwrap(Lang.locateResourceBundle(executable: link))
        XCTAssertEqual(found.bundleURL.resolvingSymlinksInPath().path,
                       bundle.resolvingSymlinksInPath().path)
    }

    func test_リンクの隣にバンドルが無くても実体の隣にあれば見つかる() throws {
        let (link, _) = try makeLayout(withBundle: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: link.deletingLastPathComponent().appendingPathComponent(Lang.resourceBundleName).path))
        XCTAssertNotNil(Lang.locateResourceBundle(executable: link))
    }

    func test_バンドルが無ければnilを返す() throws {
        let (link, _) = try makeLayout(withBundle: false)
        XCTAssertNil(Lang.locateResourceBundle(executable: link))
        XCTAssertNil(Lang.locateResourceBundle(executable: nil))
    }
}
