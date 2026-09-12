#!/bin/sh
# 配布物を作る: universal binary（arm64 + x86_64）とリソースバンドルを 1 つの zip に。
#
#     sh scripts/release.sh            # 版は最新のタグから（v0.1.0 → 0.1.0）
#     sh scripts/release.sh 0.1.0      # 版を指定
#
# 出力: dist/mrdiff-<版>-macos.zip と、その sha256（Homebrew の formula に貼る）。
#
# **バイナリ 1 つでは動かない。** SPM が Localizable.strings を MrDiff_MrDiffCore.bundle に
# まとめ、実行時に `Bundle.module` が実行ファイルの隣を探す。無ければ即落ちる
# （fatal error: unable to find bundle）。だから zip には必ず bundle を同梱し、
# formula 側も両方を libexec に置いて bin へはシンボリックリンクを張る（homebrew/mrdiff.rb）。
# シンボリックリンク経由でも bundle は見つかる（実行ファイルの実体の隣を見るため。確認済み）。
#
# zip なのは Homebrew が扱えるのと、MrShip がダウンロード数を数える拡張子に入っているため。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
if [ -z "$VERSION" ]; then
  echo "版が分からない。タグを打つか、引数で渡すこと（例: sh scripts/release.sh 0.1.0）" >&2
  exit 1
fi

swift build -c release --arch arm64 --arch x86_64
PRODUCTS=".build/apple/Products/Release"

STAGE="$(mktemp -d)"
cp "$PRODUCTS/mrdiff" "$STAGE/"
cp -R "$PRODUCTS/MrDiff_MrDiffCore.bundle" "$STAGE/"

mkdir -p dist
ZIP="dist/mrdiff-$VERSION-macos.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -qr "$ROOT/$ZIP" mrdiff MrDiff_MrDiffCore.bundle)
rm -rf "$STAGE"

echo "$ZIP"
shasum -a 256 "$ZIP" | cut -d' ' -f1
