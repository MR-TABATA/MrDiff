<p align="center"><img src="art/icon.png" width="128" alt=""></p>

# MrDiff

**Images, PDFs, binaries, URLs — and text, of course. One command, two answers: do they differ, and where.**

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

The answer has the same shape whatever you hand it, and it arrives in the
terminal you are already in. Nothing is rendered; nothing opens.

## What it does

MrDiff answers two questions: **do these differ, and where?**

It does not render the difference. For text,
[delta](https://github.com/dandavison/delta) and
[difftastic](https://github.com/Wilfred/difftastic) show a diff well, and MrDiff
does not try to replace them. What MrDiff adds is the same short answer for every
kind of input — an image, a PDF, a binary, a URL, a live site, a server, a 10 GB log
where you only care whether anything moved — without switching tools or learning
a different output for each.

| | |
| :--- | :--- |
| **Text and source** | line diff, colored, with character-level highlight |
| **Images** | do they differ, what fraction of pixels, where is the first one |
| **PDFs** | which pages differ, and where on the page — in millimetres, not pixels |
| **Binaries** | do they differ, how many regions, offset of the first |
| **Two URLs** | fetch both, diff the source they return |
| Clipboard | compare what you just copied against a file or a URL |
| **A site vs its source** | check whether a deployed site matches the git-tracked folder it was built from |
| **A local dir vs a server** | over SSH, both ways — including files left on the server that are not in your local copy |

## Install

```bash
brew install mr-tabata/tap/mrdiff
```

macOS only. Image decoding uses the system's ImageIO, which is what ties it to
the platform. Output is English by default; `MRDIFF_LANG=ja` (or `--lang=ja`
for one run) switches the human-readable lines to Japanese. JSON output and exit
codes never change, and the OS locale is never consulted — output pasted into an
issue stays readable to whoever answers it.

## Usage

```bash
mrdiff a.txt b.txt                    # text
mrdiff a.png b.png                    # image — summary, not a picture
mrdiff a.pdf b.pdf                    # PDF — which pages, where on the page (mm)
mrdiff a.bin b.bin                    # binary — summary
mrdiff https://example.com/a https://example.com/b
mrdiff --clipboard notes.md           # clipboard vs file
mrdiff --site https://example.com ./site   # is the live site in sync with ./site?
mrdiff local.conf host:/etc/app.conf       # one remote file over ssh
mrdiff --ssh ./site host:/var/www          # a whole tree over ssh, both ways

mrdiff --help                         # every option, one line each
mrdiff --help --lang=ja               # the same in Japanese
mrdiff --version                      # mrdiff 0.2.0
mrdiff --exit-code a.png b.png        # exit 1 if they differ
mrdiff --json a.bin b.bin             # machine readable

mrdiff --tolerance=2 a.png b.jpg      # ±2 per channel counts as the same
mrdiff --ignore-alpha a.png b.png     # compare colour only
mrdiff --color=never a.log b.log      # no escape codes (auto-off when piped)
```

### Text

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

Changed lines get a **character-level highlight** — in the pair above only the
`2`/`3` and the `2`/`5` are marked. Finding the one character that moved is the
point; painting the whole line red is not enough.

Line numbers are two columns, left and right. A deleted line 7 and an added line
7 are not the same line, and one column cannot say which is which.

Which kind of comparison runs is decided by **content, not extension**: two files
that decode as UTF-8 and hold no NUL byte get the line diff.

Markdown and JSON are compared this way too — line by line, as text. Reformatting
counts as a change; "the same after `**bold**` is removed" or "the same with the
keys in a different order" is outside what this version says.

### Images

The default is exact: one unit of difference in one channel is a difference.
That is deliberate — "identical" with nothing after it always means
byte-identical. `--tolerance` and `--ignore-alpha` loosen what counts as
different, and when either is on the output says so. When images differ, the
output also says how far apart the values got, and what tolerance would close
the gap:

```
Images differ — 1,051 of 1,200 pixels (87.6%)
First difference at (0, 0)
  largest per-channel gap: 36 — --tolerance=36 would call these the same
```

A lossy re-encode does not collapse to zero at a small tolerance: on the test
pair above the largest gap is 36, so `--tolerance=2` still leaves half the pixels
different. Read the gap as a measure of how far the values have spread, not as an
invitation to set the tolerance to it.

### PDFs

A PDF is what design tools hand over at the end, and a byte comparison of two
versions tells you nothing — one corrected word re-packs the compressed streams
and shifts every offset after it. MrDiff renders each page and compares pixels,
page by page, then reports positions **on the paper, in millimetres**, so the
answer is the one a proofreader wants: which page, and where on it.

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

Pages are paired by number; when the counts differ, the extra pages are listed
but not compared. A page whose paper size differs is reported as such and not
compared further, like an image of a different size. Pages are rendered at
72 dpi (one point per pixel), on white — so `--ignore-alpha` has nothing to
apply to and is refused. `--tolerance` works as for images. This is visual
comparison only: a changed word is found as a changed region, not quoted.

### URLs and the clipboard

`mrdiff https://a https://b` fetches both and compares **what the server returned** —
no JavaScript is run and nothing is rendered, so the answer can differ from what a
browser shows you. That is outside what this tool can honestly answer, and pretending
otherwise would make it a tool that claims differences where there are none.

A URL that returns an image is compared as an image; one that returns a binary is
compared as a binary. Once the bytes are in hand, everything takes the same path.

`mrdiff --clipboard notes.md` compares what you just copied against a file or a URL.
Text is taken as text; if the clipboard holds no text, a PNG or TIFF image is taken
instead — copying a screenshot and asking "is this the same as before?" is the case
this is for.

### A deployed site vs the folder it came from

```
mrdiff --site https://example.com ./site
```

Walks the **git-tracked** files under `./site`, fetches each one from the site, and
tells you what does not match:

```
changed   index.html
not on site   pricing.html
1 changed, 1 not deployed, 0 could not be checked
  note: files on the site that are not in git cannot be found this way (HTTP has no directory listing)
```

`./site` must be inside a git work tree — `git ls-files` is what defines "the files
that are meant to be there", so anything git ignores (build junk, `.DS_Store`, a file
edited straight on the server) is not counted as yours. That is deliberate: it means
this only works on a site you control, and it is what makes "did I forget to deploy
this?" answerable.

**What it cannot tell you: files on the site that are *not* in git** — a left-over
`customers.xlsx`, an old page you deleted locally. HTTP has no directory listing, so
there is no way to enumerate what the site actually holds; the command says so every
time rather than implying the site is clean.

`--exit-code` makes it a deploy check for CI.

### Over SSH

```
mrdiff local.conf host:/etc/nginx/nginx.conf     # one file
mrdiff --ssh ./site deploy@host:/var/www         # a whole directory
```

`host:/path` is fetched with `scp`; `--ssh` walks a whole tree. Authentication is left
entirely to your `ssh` — keys, `~/.ssh/config`, agent forwarding all work because
mrdiff shells out to `ssh`/`scp` rather than reimplementing any of it, and it never
asks for a password (a host it cannot reach without one simply fails).

Unlike `--site`, an SSH directory diff sees **both sides**, so it reports the third
thing a deploy check usually cannot:

```
changed   config/app.yml
only local (not deployed)   pages/new.html
only on remote (left over?)   backups/customers.sql     ← not in your local copy
1 changed, 1 only local, 1 only on remote
```

That last line is the point for anyone maintaining a server: a file sitting in the
web root that is not in your repo — an old export, a forgotten backup — is exactly
what you want flagged, and over SSH the remote side can be listed, so it can be.

### JSON

`--json` prints one line of JSON and nothing else. It is never translated,
and its shape is fixed from v0.1.0 on (`pdf` added in v0.2.0):

| key | |
| :--- | :--- |
| `kind` | what it was compared as: `text`, `image`, `pdf`, `binary`, `site` (`--site`), `tree` (`--ssh`) |
| `result` | `identical` or `differ`; images can also say `size_mismatch`; `--site` says `error` when nothing differed but some files could not be checked |
| text | `changed`, `added`, `removed`. `changed` counts a replaced block as the larger of its two sides — one line deleted and two inserted in its place is `changed: 2` |
| image | `changed`, `total`, `fraction`, `first: {x, y}`, `max_gap` (the largest per-channel difference — `--tolerance=<max_gap>` would call the two the same); on `size_mismatch`, `a` and `b` as `{width, height}`. `tolerance` and `ignore_alpha` appear only when they were used — no key means byte-strict. `tone_shift` is the mean signed difference B − A per channel — a photo that is "44% different" because it was exported brighter shows up here as `[21.3, 18.6, 17.7]` |
| pdf | `pages_a`, `pages_b`, `dpi`, and `pages: [{page, result, …}]` for the pages both have — a differing page carries `changed`, `total`, `fraction`, `max_gap` and `regions: [{top_mm, left_mm, width_mm, height_mm, count}]`; a `size_mismatch` page carries `a` and `b` as `{width_mm, height_mm}`. `result` at the top is `differ` whenever the page counts differ, even if every shared page is identical |
| binary | `regions`, `differing_bytes`, `first: {offset}` (null when only the lengths differ), `size_a`, `size_b` |
| site / tree | `in_sync`, `files`, per-status counts, and `rows: [{path, status}]` |
| any | `redirected: [{from, to}]` when a URL was redirected |

```
$ mrdiff --json a.png b.png
{"changed":3,"first":{"x":4,"y":5},"fraction":0.03,"kind":"image","max_gap":7,"result":"differ","total":100}
```

Exit codes: `0` it ran (differ or not), `1` they differ and `--exit-code` was
given, `2` it could not run (the reason goes to stderr; nothing goes to stdout).

### In CI

`--exit-code` makes it a check. Screenshot regression, firmware build
comparison, "did the generated file change" — the cases where you do not need
to see the difference, only to know there is one.

```yaml
- run: mrdiff --exit-code baseline.png current.png
```

## Why

Every kind of file already has a diff tool of its own. Text has `diff`, delta,
difftastic. Images have odiff and pixelmatch. Binaries have `cmp -l` and
radiff2. A server has `rsync -n`. Each one answers well; the cost is remembering
which one to reach for, and reading a different output from each.

MrDiff asks one question of all of them — do these differ, and where — and
answers it in one shape. When that answer is not enough and you actually need to
*see* the difference, that is a different tool's job.

## Speed

**Reading is the cost.** To say that two files are identical, both have to be
read to the end — there is no way around that, and no amount of hashing avoids
it. What the block pass avoids is the *byte-by-byte* comparison inside blocks
that already match, which is why a 1 GB file with a 5-byte change costs about
the same as a 1 GB file that is identical.

| file size | changed | time | of which CPU |
| ---: | ---: | ---: | ---: |
| 1 GB (binary) | 5 bytes | **4.26 s** | 0.51 s |
| 1 GB (binary) | none, warm cache | 0.12 s | 0.11 s |

*(Measured on an M4 Max, 2026-09-11, release build. The first row is a cold
read of two 1 GB files; the second is the same file twice, already in the page
cache — it is here to show that the work is in the I/O, not in the compare.)*

## License

MIT.
