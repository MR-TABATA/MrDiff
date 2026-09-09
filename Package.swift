// swift-tools-version: 5.9
import PackageDescription

// 1 つのコアを CLI と（将来）GUI が共有する。MrEditor と同じ形。
//
//   MrDiffCore (library) ── 判定と比較。表示は持たない。
//        └── mrdiff  (executable) … 無料の CLI。MIT。
//
// **MrEditorCore にはまだ依存しない。** 巨大テキストの機構が要るのは
// テキスト diff を実装するときで、それまで引くと AppKit ごと持ち込むことになる。
// CLI を Linux（CI）でも動かす目があるので、要るまで足さない。
let package = Package(
    name: "MrDiff",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MrDiffCore", targets: ["MrDiffCore"]),
        .executable(name: "mrdiff", targets: ["mrdiff"]),
    ],
    targets: [
        .target(name: "MrDiffCore"),
        .executableTarget(name: "mrdiff", dependencies: ["MrDiffCore"]),
        .testTarget(name: "MrDiffTests", dependencies: ["MrDiffCore"]),
    ]
)
