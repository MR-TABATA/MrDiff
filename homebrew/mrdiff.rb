# Homebrew の formula。**ここは下書きの置き場で、brew はここを読まない。**
# 公開するときは MR-TABATA/homebrew-tap リポジトリの Formula/mrdiff.rb に置く。
# そうすると `brew install mr-tabata/tap/mrdiff` で入る。
#
# 版を上げるたびに url / sha256 / version の 3 行を Release に合わせて書き換える
# （sha256 は Release の本文と Actions のログに出る）。
#
# ビルド済みバイナリを入れる形（ソースから swift build しない）。
# 数秒で入り、Xcode も要らず、ダウンロード数が Release のアセットに乗る。
class Mrdiff < Formula
  desc "Do they differ, and where — images, PDFs, Word, fonts, archives, folders, URLs, sites, SSH, and text"
  homepage "https://mr-tabata.github.io/MrDiff/"
  url "https://github.com/MR-TABATA/MrDiff/releases/download/v0.5.0/mrdiff-0.5.0-macos.zip"
  sha256 "c7c9981a1135c83909e4b4c9eee0e601005b551ed95fd9aa9c4d8e3eba0f1b09"
  version "0.5.0"
  license "MIT"

  depends_on :macos => :ventura # Package.swift の platforms（.v13）と同じ

  def install
    # バイナリ 1 つでは動かない。SPM のリソースバンドルが実行ファイルの隣に要る
    # （scripts/release.sh の注記）。両方を libexec に置き、bin にはリンクだけ張る。
    libexec.install "mrdiff", "MrDiff_MrDiffCore.bundle"
    bin.install_symlink libexec/"mrdiff"
  end

  test do
    (testpath/"a.txt").write "one\n"
    (testpath/"b.txt").write "two\n"
    assert_match "changed", shell_output("#{bin}/mrdiff --exit-code a.txt b.txt", 1)
    assert_match "No differences", shell_output("#{bin}/mrdiff a.txt a.txt")
  end
end
