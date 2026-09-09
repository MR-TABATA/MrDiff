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

> **Status: not built yet.** This README is the design. Nothing here runs today.
> Numbers marked `TODO` are unmeasured — they will be filled in from real runs,
> not estimates.

## What it does

MrDiff answers two questions: **do these differ, and where?**

It does not render the difference. For text there are already good tools for
that — [delta](https://github.com/dandavison/delta) and
[difftastic](https://github.com/Wilfred/difftastic) — and MrDiff does not try to
replace them. What no CLI answers today is the same question about an image, or
a binary, or a 10 GB log where you only care whether anything moved.

| | |
| :--- | :--- |
| Text and source | line diff, colored |
| **Images** | do they differ, what fraction of pixels, where is the first one |
| **Binaries** | do they differ, how many regions, offset of the first |
| **Two URLs** | fetch both, diff the HTML source |
| Clipboard | compare what you just copied against a file |

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

mrdiff --exit-code a.png b.png        # exit 1 if they differ
mrdiff --format json a.bin b.bin      # machine readable
```

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

MrDiff does not compare every byte when it does not have to. It hashes blocks
first and only looks inside the blocks that disagree, so a large file with a
small change is cheap to answer for. The cost is proportional to how much
changed, not to how big the file is.

| file size | changed | time |
| ---: | ---: | ---: |
| 1 GB | 5 lines | TODO |
| 10 GB | 5 lines | TODO |

*(Measured, not estimated. Empty until it is.)*

## License

MIT.
