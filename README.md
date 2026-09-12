<p align="center"><img src="art/icon.png" width="128" alt=""></p>

# MrDiff

**`diff` tells you binary files differ. It does not tell you how much, or where.**

```
$ diff before.png after.png
Binary files before.png and after.png differ
```

That is the whole answer you get. MrDiff gives you the rest of it, on the
command line, without opening anything.

```
$ mrdiff before.png after.png
Images differ — 3.2% of pixels (12,481 / 390,000)
First difference at (412, 88)

$ mrdiff firmware-v1.bin firmware-v2.bin
Binary files differ — 47 regions, first at 0x1A3F

$ mrdiff config.json config-new.json
5 changed, 1 added, 0 removed
```

> **Status: text, images, binaries, URLs, the clipboard, a site-vs-git check and
> SSH (single file and whole directory) all work.**
> This README is still partly design. Numbers marked `TODO` are unmeasured —
> they will be filled in from real runs, not estimates.

## What it does

MrDiff answers two questions: **do these differ, and where?**

It does not render the difference. For text there are already good tools for
that — [delta](https://github.com/dandavison/delta) and
[difftastic](https://github.com/Wilfred/difftastic) — and MrDiff does not try to
replace them. What no CLI answers today is the same question about an image, or
a binary, or a 10 GB log where you only care whether anything moved.

| | |
| :--- | :--- |
| **Text and source** | line diff, colored, with character-level highlight |
| **Images** | do they differ, what fraction of pixels, where is the first one |
| **Binaries** | do they differ, how many regions, offset of the first |
| **Two URLs** | fetch both, diff the source they return |
| Clipboard | compare what you just copied against a file or a URL |
| **A site vs its source** | check whether a deployed site matches the git-tracked folder it was built from |
| **A local dir vs a server** | over SSH, both ways — including files left on the server that are not in your local copy |

## Install

```bash
brew install mr-tabata/tap/mrdiff     # TODO: tap not published yet
```

## Usage

```bash
mrdiff a.txt b.txt                    # text
mrdiff a.png b.png                    # image — summary, not a picture
mrdiff a.bin b.bin                    # binary — summary
mrdiff https://example.com/a https://example.com/b
mrdiff --clipboard notes.md           # clipboard vs file
mrdiff --site https://example.com ./site   # is the live site in sync with ./site?
mrdiff local.conf host:/etc/app.conf       # one remote file over ssh
mrdiff --ssh ./site host:/var/www          # a whole tree over ssh, both ways

mrdiff --exit-code a.png b.png        # exit 1 if they differ
mrdiff --format json a.bin b.bin      # machine readable

mrdiff --tolerance=2 a.png b.jpg      # ±2 per channel counts as the same
mrdiff --ignore-alpha a.png b.png     # compare colour only
mrdiff --color=never a.log b.log      # no escape codes (auto-off when piped)
```

### Text

```
$ mrdiff a.log b.log
2 changed, 1 added, 0 removed
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

`--tolerance` and `--ignore-alpha` loosen what counts as different. When either
is on, the output says so — "identical" on its own always means byte-identical.

A lossy re-encode does not collapse to zero at a small tolerance: on the test
pair the largest per-channel gap is 36, so `--tolerance=2` still leaves half the
pixels different. Read it as a measure of how far the values have spread, not as
a way to call two files the same.

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
In sync — 12 files match the site
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
```

That last line is the point for anyone maintaining a server: a file sitting in the
web root that is not in your repo — an old export, a forgotten backup — is exactly
what you want flagged, and over SSH the remote side can be listed, so it can be.

### In CI

`--exit-code` makes it a check. Screenshot regression, firmware build
comparison, "did the generated file change" — the cases where you do not need
to see the difference, only to know there is one.

```yaml
- run: mrdiff --exit-code baseline.png current.png
```

## Why

Every diff tool is built for text. The moment the file is a PNG or a `.bin`,
they all say the same thing — *files differ* — and stop. So you open a GUI, wait
for it to load, look at one number, and close it again.

That is a slow way to answer a fast question.

MrDiff is the fast answer. When the fast answer is not enough and you actually
need to *see* it, that is a different tool's job.

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
