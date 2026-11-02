// swift-tools-version: 5.9
import PackageDescription

// 1 つのコアを CLI と（将来）GUI が共有する。MrEditor と同じ形。
//
//   MrDiffCore (library) ── 判定と比較。表示は持たない。
//   MrDiffPostgres (target) ── PostgreSQL 比較。PostgresNIO を使う。
//        └── MrDiffCore の翻訳を使い、mrdiff から呼び出す。
//   mrdiff (executable) … 無料の CLI。MIT。
//
// **MrEditorCore には依存しない。** テキスト diff は LineDiff / CharDiff を
// 写して持っている（共有しない・同期しない）。引くと AppKit ごと持ち込むことになる。
//
// macOS 専用。ImageIO / CoreGraphics で画像を読む時点で Apple のプラットフォームに
// 縛られているので、Linux で動かす目は捨てた（platforms も macOS だけ）。
let package = Package(
    name: "MrDiff",
    // 既定は英語。日本語は MRDIFF_LANG=ja で明示的に選んだときだけ（Localization.swift）
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MrDiffCore", targets: ["MrDiffCore"]),
        .executable(name: "mrdiff", targets: ["mrdiff"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0")
    ],
    targets: [
        .target(
            name: "MrDiffCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "MrDiffPostgres",
            dependencies: [
                "MrDiffCore",
                .product(name: "PostgresNIO", package: "postgres-nio")
            ]
        ),
        .executableTarget(name: "mrdiff", dependencies: ["MrDiffCore", "MrDiffPostgres"]),
        .testTarget(
            name: "MrDiffTests",
            dependencies: ["MrDiffCore", "MrDiffPostgres", "mrdiff"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
