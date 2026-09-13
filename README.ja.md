<p align="center"><img src="art/icon.png" width="128" alt=""></p>

# MrDiff

**画像も PDF もバイナリも URL も、もちろんテキストも。1 つのコマンドで、答えは 2 つ ── 違うか、どこが。**

[English](README.md)

```
$ mrdiff before.png after.png
Images differ — 12,481 of 390,000 pixels (3.2%)
First difference at (412, 88)
  largest per-channel gap: 41 — --tolerance=41 would call these the same

$ mrdiff proof-v1.pdf proof-v2.pdf
PDFs differ — 1 of 12 pages
p.7  2 regions
     top 107 mm, left 25 mm, 71 × 14 mm
     top 205 mm, left 106 mm, 21 × 21 mm

$ mrdiff firmware-v1.bin firmware-v2.bin
Binary files differ — 47 regions, first at 0x1A3F
  158 of 2,000,000 bytes differ

$ mrdiff config.json config-new.json
5 changed, 1 added, 0 removed

$ mrdiff --ssh ./site deploy@host:/var/www
changed   config/app.yml
only local (not deployed)   pages/new.html
only on remote (left over?)   backups/customers.sql
1 changed, 1 only local, 1 only on remote
```

何を渡しても答えは同じ形で、いま開いているターミナルに返ってくる。
絵は出さない。ウィンドウも開かない。

## 何をするか

MrDiff が答えるのは 2 つ。**違うか、どこが。**

差分を描いて見せることはしない。テキストなら
[delta](https://github.com/dandavison/delta) や
[difftastic](https://github.com/Wilfred/difftastic) がよく見せてくれるので、
MrDiff はそれに取って代わろうとしない。MrDiff が足すのは、どの入力にも同じ短い答え ──
画像、PDF、バイナリ、URL、公開中のサイト、サーバ、「何か動いたか」だけ知りたい
10 GB のログ ── を、道具を持ち替えず、種類ごとに違う出力を覚えずに返すこと。

| | |
| :--- | :--- |
| **テキストとソース** | 行の差分。色つき、文字単位のハイライト |
| **画像** | 違うか、画素の何割が、最初はどこか |
| **PDF** | どのページが違い、そのページのどこか ── 画素ではなく mm で |
| **バイナリ** | 違うか、違う箇所はいくつか、最初のオフセットはどこか |
| **URL 2 つ** | 両方取ってきて、返ってきたソースを比べる |
| クリップボード | いまコピーしたものを、ファイルか URL と比べる |
| **サイトとその元** | 公開中のサイトが、元になった git 管理下のフォルダと合っているか |
| **手元のディレクトリとサーバ** | SSH 越しに両方向 ── 手元に無くサーバに残っているファイルも |

## インストール

```bash
brew install mr-tabata/tap/mrdiff
```

最新のリリースに上げるには：

```bash
brew update && brew upgrade mrdiff
mrdiff --version                      # 確認
```

`brew update` で tap を読み直さないと、Homebrew が新しい版に気づかず
`brew upgrade` が「もう入っている」と言うことがある。何が変わったかは
[Releases](https://github.com/MR-TABATA/MrDiff/releases) と
[リリース履歴](https://mr-tabata.github.io/MrDiff/releases.ja.html)に。

macOS 専用。画像の読み込みに OS の ImageIO を使っていて、それが
プラットフォームに縛られる理由。出力は既定で英語。`MRDIFF_LANG=ja`（1 回だけなら
`--lang=ja`）で人が読む行が日本語になる。JSON の出力と終了コードは変わらず、
OS のロケールも見ない ── Issue に貼った出力が、答える側の誰にでも読めるように。

## 使い方

```bash
mrdiff a.txt b.txt                    # テキスト
mrdiff a.png b.png                    # 画像 ── 要約。絵は出さない
mrdiff a.pdf b.pdf                    # PDF ── どのページの、どこか（mm）
mrdiff a.bin b.bin                    # バイナリ ── 要約
mrdiff https://example.com/a https://example.com/b
mrdiff --clipboard notes.md           # クリップボード vs ファイル
mrdiff --site https://example.com ./site   # 公開中のサイトは ./site と合っているか
mrdiff local.conf host:/etc/app.conf       # ssh 越しのファイル 1 つ
mrdiff --ssh ./site host:/var/www          # ssh 越しのツリー全体、両方向

mrdiff --help                         # オプションの一覧。1 つ 1 行
mrdiff --help --lang=ja               # 同じものを日本語で
mrdiff --version                      # mrdiff 0.2.0
mrdiff --exit-code a.png b.png        # 違えば 1 で終わる
mrdiff --json a.bin b.bin             # 機械向け

mrdiff --tolerance=2 a.png b.jpg      # チャンネルごとに ±2 までは同じとみなす
mrdiff --ignore-alpha a.png b.png     # 色だけ比べる
mrdiff --color=never a.log b.log      # 制御文字を出さない（パイプなら自動で切れる）
```

### テキスト

```
$ mrdiff a.log b.log
2 changed, 0 added, 0 removed
    1     1   09:00:01 INFO  starting worker pool size=8
    2     2   09:00:02 INFO  connected to db host=primary
    3       - 09:00:03 INFO  GET /health status=200 latency=42ms
          3 + 09:00:03 INFO  GET /health status=200 latency=43ms
    4       - 09:00:04 INFO  GET /users status=200 latency=18ms
          4 + 09:00:04 INFO  GET /users status=500 latency=18ms
    5     5   09:00:05 INFO  GET /orders status=200 latency=61ms
```

変わった行には**文字単位のハイライト**が付く ── 上の例では `2`/`3` と `2`/`5` だけに
印が付く。動いた 1 文字を見つけるのが目的で、行ごと赤く塗るだけでは足りない。

行番号は左右 2 列。消えた 7 行目と増えた 7 行目は同じ行ではなく、1 列ではどちらが
どちらか言えない。

どの比較を走らせるかは**拡張子ではなく中身**で決める。UTF-8 として読めて NUL バイトが
無い 2 つは、行の差分になる。

Markdown と JSON もこの方法 ── 行ごとに、テキストとして ── で比べる。整形し直しは
変更と数える。「`**太字**` を外せば同じ」や「キーの順が違うだけで同じ」は、この版が
言うことの外側。

### 画像

既定は厳密。1 チャンネルで 1 だけ違っても違い。これは意図したもので、後ろに何も
付かない「同じ」は、必ずバイト単位で同じという意味。`--tolerance` と
`--ignore-alpha` は「違い」の範囲を緩め、どちらかが効いているときは出力にそう書く。
違ったときは、値がどれだけ離れていたかと、いくつ緩めれば埋まるかも言う：

```
Images differ — 1,051 of 1,200 pixels (87.6%)
First difference at (0, 0)
  largest per-channel gap: 36 — --tolerance=36 would call these the same
```

非可逆の再エンコードは、小さな tolerance では 0 にならない。上の組では最大の差が 36
なので、`--tolerance=2` でも画素の半分は違ったまま。この数は「値がどれだけ散ったか」の
物差しであって、そこまで緩めよという勧めではない。

### PDF

PDF はデザインの道具が最後に手渡す形で、2 つの版をバイトで比べても何も分からない ──
1 語直しただけで圧縮ストリームが組み直され、以降のオフセットが全部ずれる。MrDiff は
ページごとに描いて画素で比べ、位置を**紙の上の mm** で言う。校正で知りたい答え ──
どのページの、どこか ── になる。

```
$ mrdiff proof-v1.pdf proof-v2.pdf
Page count differs — 12 vs 13
PDFs differ — 1 of 12 pages
p.7  2 regions
     top 107 mm, left 25 mm, 71 × 14 mm
     top 205 mm, left 106 mm, 21 × 21 mm
p.13  only in B
  pages rendered at 72 dpi; positions are on the page, in mm
```

ページは番号で対にする。ページ数が違えば、余ったページは列挙するだけで比べない。
紙の大きさが違うページはそう言ってそれ以上比べない（大きさの違う画像と同じ）。
ページは 72 dpi（1 pt = 1 px）で白地に描くので、`--ignore-alpha` には効く相手が無く、
断る。`--tolerance` は画像と同じに効く。見た目の比較だけで、変わった語は
「変わった領域」として見つかるが、文字としては引用しない。

### URL とクリップボード

`mrdiff https://a https://b` は両方を取ってきて、**サーバが返したもの**を比べる ──
JavaScript は走らせず、描画もしないので、ブラウザで見えるものと答えが違うことがある。
それはこの道具が正直に答えられる範囲の外で、答えられるふりをすれば、無い違いを
あると言う道具になる。

画像を返す URL は画像として、バイナリを返す URL はバイナリとして比べる。バイトが
手に入った後は、全部同じ道を通る。

`mrdiff --clipboard notes.md` は、いまコピーしたものをファイルか URL と比べる。
テキストがあればテキストとして、無ければ PNG か TIFF の画像として取る ──
スクリーンショットをコピーして「さっきと同じか」と聞く場面のため。

### 公開中のサイトと、その元のフォルダ

```
mrdiff --site https://example.com ./site
```

`./site` の下の **git 管理下**のファイルを 1 つずつサイトから取ってきて、合わないものを言う：

```
changed   index.html
not on site   pricing.html
1 changed, 1 not deployed, 0 could not be checked
  note: files on the site that are not in git cannot be found this way (HTTP has no directory listing)
```

`./site` は git のワークツリーの中にある必要がある ── 「そこにあるべきファイル」を
決めるのは `git ls-files` で、git が無視するもの（ビルドのゴミ、`.DS_Store`、サーバ上で
直接直したファイル）は自分のものと数えない。これは意図したもので、自分が管理している
サイトにしか効かない代わりに、「これ、デプロイし忘れた？」に答えられる。

**言えないこと：サイトにあって git に*無い*ファイル** ── 置き忘れの `customers.xlsx`、
手元で消した古いページ。HTTP にはディレクトリの一覧が無いので、サイトが実際に何を
持っているかは列挙できない。コマンドは毎回そう言い、サイトがきれいだと匂わせない。

`--exit-code` を付ければ CI のデプロイ検査になる。

### SSH 越し

```
mrdiff local.conf host:/etc/nginx/nginx.conf     # ファイル 1 つ
mrdiff --ssh ./site deploy@host:/var/www         # ディレクトリ全体
```

`host:/path` は `scp` で取り、`--ssh` はツリー全体を歩く。認証は手元の `ssh` に
全部任せる ── 鍵、`~/.ssh/config`、agent forwarding、どれも効く。mrdiff は
`ssh`/`scp` を呼ぶだけで自前で実装し直さず、パスワードも決して聞かない
（パスワード無しで届かないホストは、そのまま失敗する）。

`--site` と違って、SSH のディレクトリ diff は**両側**が見えるので、デプロイ検査が
普通は言えない 3 つ目を言う：

```
changed   config/app.yml
only local (not deployed)   pages/new.html
only on remote (left over?)   backups/customers.sql     ← 手元に無い
1 changed, 1 only local, 1 only on remote
```

サーバを守っている人にはこの最後の行が要点になる。web root に置かれた、リポジトリに
無いファイル ── 古い書き出し、忘れられたバックアップ ── こそ印を付けたいもので、SSH
なら向こう側を列挙できるので、付けられる。

### JSON

`--json` は 1 行の JSON だけを出す。訳さない。形は v0.1.0 から固定
（`pdf` は v0.2.0 で追加）：

| キー | |
| :--- | :--- |
| `kind` | 何として比べたか：`text`、`image`、`pdf`、`binary`、`site`（`--site`）、`tree`（`--ssh`） |
| `result` | `identical` か `differ`。画像は `size_mismatch` も。`--site` は、違いは無いが確認できなかったファイルがあれば `error` |
| text | `changed`、`added`、`removed`。`changed` は置き換えられた塊を両側の大きいほうで数える ── 1 行消して 2 行足せば `changed: 2` |
| image | `changed`、`total`、`fraction`、`first: {x, y}`、`max_gap`（チャンネルごとの差の最大 ── `--tolerance=<max_gap>` なら同じになる）。`size_mismatch` なら `a` と `b` が `{width, height}`。`tolerance` と `ignore_alpha` は使ったときだけ付く ── キーが無ければバイト単位の厳密比較。`tone_shift` は B − A のチャンネルごとの平均（符号付き）── 明るく書き出されたせいで「44% 違う」写真は、ここに `[21.3, 18.6, 17.7]` のように出る |
| pdf | `pages_a`、`pages_b`、`dpi`、両方にあるページの `pages: [{page, result, …}]`。違うページは `changed`、`total`、`fraction`、`max_gap`、`regions: [{top_mm, left_mm, width_mm, height_mm, count}]` を持つ。`size_mismatch` のページは `a` と `b` が `{width_mm, height_mm}`。一番上の `result` は、共通ページが全部同じでもページ数が違えば `differ` |
| binary | `regions`、`differing_bytes`、`first: {offset}`（長さだけ違うなら null）、`size_a`、`size_b` |
| site / tree | `in_sync`、`files`、状態ごとの数、`rows: [{path, status}]` |
| 共通 | URL が飛ばされたときの `redirected: [{from, to}]` |

```
$ mrdiff --json a.png b.png
{"changed":3,"first":{"x":4,"y":5},"fraction":0.03,"kind":"image","max_gap":7,"result":"differ","total":100}
```

終了コード：`0` 実行できた（違っても違わなくても）、`1` 違いがあり `--exit-code` を
付けていた、`2` 実行できなかった（理由は stderr へ。stdout には何も出ない）。

### CI で

`--exit-code` を付ければ検査になる。スクリーンショットの回帰、ファームウェアの
ビルド比較、「生成したファイルは変わったか」── 違いを見る必要は無く、あるかどうかだけ
知りたい場面。

```yaml
- run: mrdiff --exit-code baseline.png current.png
```

## なぜ

ファイルの種類ごとに、diff の道具はもうある。テキストには `diff`、delta、difftastic。
画像には odiff と pixelmatch。バイナリには `cmp -l` と radiff2。サーバには `rsync -n`。
どれもよく答える。代価は、どれを取り出すか覚えておくことと、それぞれ違う出力を
読むこと。

MrDiff はその全部に 1 つの問い ── 違うか、どこが ── を投げ、1 つの形で答える。
その答えで足りず、本当に差分を*見る*必要があるなら、それは別の道具の仕事。

## 速さ

**読むことが代価。** 2 つのファイルが同じだと言うには、両方を最後まで読むしかない ──
ハッシュをどう使っても避けられない。ブロック単位の比較が避けるのは、すでに一致した
ブロックの中の*バイト単位*の比較で、だから 5 バイト違う 1 GB は、同じ 1 GB と
ほぼ同じ時間で済む。

| ファイルの大きさ | 変更 | 時間 | うち CPU |
| ---: | ---: | ---: | ---: |
| 1 GB（バイナリ） | 5 バイト | **4.26 s** | 0.51 s |
| 1 GB（バイナリ） | 無し、キャッシュ済み | 0.12 s | 0.11 s |

*（M4 Max、2026-09-11、release ビルドで計測。1 行目は 1 GB のファイル 2 つを
コールドで読んだもの。2 行目は同じファイル 2 回で、すでにページキャッシュにある ──
仕事が比較ではなく I/O にあることを示すために置いてある。）*

## ライセンス

MIT。
