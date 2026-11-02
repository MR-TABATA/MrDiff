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
# **リンク経由だと bundle は、リンクの隣しか探されない**（0.9.0 で確認: arch 別ビルドにしてから。
# 0.8.3 までは実体の隣も見つかっていた）。だから formula は bin にも bundle のリンクを張る。
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

# build の進捗は stderr へ。stdout は下の 2 行（zip のパスと sha256）だけにする ──
# 呼ぶ側（Actions）が行番号で拾うので、ここに混ざると別の文字列を掴む（1 回やった）。
# --version が言う版とタグが違う配布物は出さない。
DECLARED=$(sed -n 's/^let mrdiffVersion = "\(.*\)"$/\1/p' Sources/mrdiff/Version.swift)
if [ "$DECLARED" != "$VERSION" ]; then
  echo "Sources/mrdiff/Version.swift は ${DECLARED}、配る版は ${VERSION}。先に Version.swift を直すこと" >&2
  exit 1
fi

# universal は arch ごとに別々にビルドして lipo で束ねる。`--arch arm64 --arch x86_64` の同時指定は、
# Xcode 16.4（Actions の macos-15）で依存の swift-service-lifecycle が
# "duplicate output file" になって落ちる（0.9.0 で Postgres の依存が入ってから）。
# scratch-path を分けないと、2 回目のビルドが 1 回目の出力を同じ場所に上書きする。
swift build -c release --arch arm64 --scratch-path .build/rel-arm64 1>&2
swift build -c release --arch x86_64 --scratch-path .build/rel-x86_64 1>&2
ARM="$(swift build -c release --arch arm64 --scratch-path .build/rel-arm64 --show-bin-path)"
X86="$(swift build -c release --arch x86_64 --scratch-path .build/rel-x86_64 --show-bin-path)"

STAGE="$(mktemp -d)"
lipo -create "$ARM/mrdiff" "$X86/mrdiff" -output "$STAGE/mrdiff"
cp -R "$ARM/MrDiff_MrDiffCore.bundle" "$STAGE/"

mkdir -p dist
ZIP="dist/mrdiff-$VERSION-macos.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -qr "$ROOT/$ZIP" mrdiff MrDiff_MrDiffCore.bundle)
rm -rf "$STAGE"

# 配った zip を Homebrew と同じ配置（libexec に実体、bin にリンク）で動かして確かめる。
# 0.9.0 は、リンク経由だと bundle が見つからず `--completions zsh` が落ちたのに、直接実行では気づけなかった。
# 落ちるなら、配布物として出さない。出力は stderr へ（stdout は下の 2 行だけ）。
# ビルド先の絶対パスにも bundle のフォールバックがあり、ビルドした同じ機械では、リンクが足りなくても
# そこで見つかってしまう（検査をすり抜ける）。検査の間だけビルド先の bundle を退避させる。
CHECK="$(mktemp -d)"
for B in "$ARM" "$X86"; do mv "$B/MrDiff_MrDiffCore.bundle" "$B/MrDiff_MrDiffCore.bundle.hold"; done
restore_bundles() {
  for B in "$ARM" "$X86"; do
    [ -d "$B/MrDiff_MrDiffCore.bundle.hold" ] && mv "$B/MrDiff_MrDiffCore.bundle.hold" "$B/MrDiff_MrDiffCore.bundle"
  done
  rm -rf "$CHECK"
}
trap restore_bundles EXIT
mkdir -p "$CHECK/libexec" "$CHECK/bin"
unzip -q "$ZIP" -d "$CHECK/libexec"
ln -s ../libexec/mrdiff "$CHECK/bin/mrdiff"
ln -s ../libexec/MrDiff_MrDiffCore.bundle "$CHECK/bin/MrDiff_MrDiffCore.bundle"
for SHELL_NAME in bash zsh fish; do
  if ! "$CHECK/bin/mrdiff" --completions "$SHELL_NAME" >/dev/null 2>"$CHECK/err"; then
    echo "配布物の検査に失敗: リンク経由の mrdiff --completions $SHELL_NAME" >&2
    cat "$CHECK/err" >&2
    rm -f "$ZIP"
    exit 1
  fi
done
GOT="$("$CHECK/bin/mrdiff" --version)"
if [ "$GOT" != "mrdiff $VERSION" ]; then
  echo "配布物の検査に失敗: --version が「$GOT」（期待は「mrdiff $VERSION」）" >&2
  rm -f "$ZIP"
  exit 1
fi

echo "$ZIP"
shasum -a 256 "$ZIP" | cut -d' ' -f1
