import Foundation
import MrDiffCore

// **違うかどうかと、どこが**を答える。テキストなら色つきの行差分、
// 画像なら「何画素・どこ」。絵は出さない（それは GUI の仕事）。
//
// **人が読む出力だけ t() を通す。** --json と終了コードは通さない ――
// 訳すと grep を書いた人のスクリプトが日本語環境で壊れる。

// **ページャを q で抜けたときに SIGPIPE で落ちない。**書き込み側で EPIPE として
// 受け取り、そこで静かにやめる（Out.flush）。
signal(SIGPIPE, SIG_IGN)

let args = Array(CommandLine.arguments.dropFirst())
let wantsJSON = args.contains("--format=json") || args.contains("--json")
let wantsExitCode = args.contains("--exit-code")
let ignoreAlpha = args.contains("--ignore-alpha")
let noPager = args.contains("--no-pager")
let files = args.filter { !$0.hasPrefix("-") }

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("mrdiff: " + message + "\n").utf8))
    exit(2)
}

// **`--tolerance=N` の形だけ受ける。**空白区切り（`--tolerance 2`）を許すと、
// 2 がファイル名の側に落ちて「使い方」が出る ―― 黙って 0 で走るよりはよい。
var tolerance = 0
if let raw = args.first(where: { $0.hasPrefix("--tolerance=") })?
    .dropFirst("--tolerance=".count) {
    guard let n = Int(raw), n >= 0 else { die(t("error.bad_tolerance")) }
    tolerance = n
}

// 色。**既定は「端末なら付ける」。**パイプへ流したときに制御文字が混じると、
// grep にかけた人の手元で壊れる。NO_COLOR（no-color.org）も見る。
let useColor: Bool = {
    if let raw = args.first(where: { $0.hasPrefix("--color=") })?
        .dropFirst("--color=".count) {
        switch raw {
        case "always": return true
        case "never": return false
        case "auto": break
        default: die(t("error.bad_color"))
        }
    }
    if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
    return isatty(FileHandle.standardOutput.fileDescriptor) == 1
}()

// **入れ物は 3 種類**（ファイル・URL・クリップボード）。取ってきた後は同じ道を通る。
let useClipboard = args.contains("--clipboard")
let inputs: [Input]
if useClipboard {
    // `mrdiff --clipboard notes.md` ＝ クリップボード vs 相手 1 つ。
    guard files.count == 1 else { die(t("error.clipboard_needs_one")) }
    inputs = [.clipboard, Input.parse(files[0])]
} else {
    guard files.count == 2 else { die(t("error.usage")) }
    inputs = [Input.parse(files[0]), Input.parse(files[1])]
}

let dataA: Data, dataB: Data
var redirects: [String] = []
do {
    let ra = try inputs[0].readDetailed()
    let rb = try inputs[1].readDetailed()
    dataA = ra.data
    dataB = rb.data
    // **飛ばされたら、そう言う。**打った URL と中身を取った URL が違うのに黙っていると、
    // 「何と何を比べた結果なのか」が消える。
    for (input, fetched) in zip(inputs, [ra, rb]) {
        if let landed = fetched.finalURL {
            redirects.append(t("note.redirected", input.label, landed.absoluteString))
        }
    }
} catch {
    die("\(error)")
}

/// 飛ばし先の注意書きを出す。**JSON には出さない**（機械向けは静かに保つ）。
func printRedirects() {
    guard !wantsJSON else { return }
    for line in redirects { print("  " + line) }
}

// 画像の比較だけは**ファイルの URL が要る**（ImageIO へ渡すため）。
// URL やクリップボードから来たものは、一時ファイルへ書いてから渡す。
func fileURL(for input: Input, data: Data, suffix: String) throws -> URL {
    if case .file(let u) = input { return u }
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mrdiff-\(UUID().uuidString)-\(suffix)")
    try data.write(to: tmp)
    return tmp
}

if detectKind(dataA) == .text && detectKind(dataB) == .text {
    // **効かないつまみを黙って飲まない。**--tolerance と --ignore-alpha は画素の話で、
    // 行には意味が無い。黙って無視すると「指定したのに効いていない」に気づけない。
    if tolerance > 0 || ignoreAlpha { die(t("error.image_only_flag")) }

    let d = compareText(TextSource(data: dataA), TextSource(data: dataB))
    if wantsJSON {
        if d.isIdentical {
            print(#"{"result":"identical"}"#)
        } else {
            print("{\"result\":\"differ\",\"changed\":\(d.changed),\"added\":\(d.added),\"removed\":\(d.removed)}")
        }
    } else if d.isIdentical {
        print(t("text.identical"))
        printRedirects()
    } else {
        // **サマリも同じ口から出す。**print（libc のバッファ）と Out（fd へ直接）を
        // 混ぜると、順番が入れ替わる ―― 実際にサマリが本文の後ろへ回った。
        // 端末に出すときだけページャへ渡す。パイプならそのまま流す。
        let sink = Pager.command(disabled: noPager).flatMap { Pager.start($0) }
        var out = Out(to: sink ?? stdout)
        out.line(t("text.summary", d.changed, d.added, d.removed))
        for line in redirects { out.line("  " + line) }
        renderText(d, style: Style(on: useColor), into: &out)
        out.flush()
        Pager.finish()
    }
    exit(d.isIdentical ? 0 : (wantsExitCode ? 1 : 0))
}

// **片方だけテキストなら、比べない。**行と画素は突き合わせられない。
if detectKind(dataA) != detectKind(dataB) { die(t("error.mixed_kinds")) }

// テキストでないものは、**画像として読めるかどうか**でさらに分ける。拡張子は見ない。
// 片方だけ画像なら比べない（画素と生バイトも突き合わせられない）。
let imageA = looksLikeImage(dataA), imageB = looksLikeImage(dataB)
if imageA != imageB { die(t("error.mixed_kinds")) }

if !imageA {
    if tolerance > 0 || ignoreAlpha { die(t("error.image_only_flag")) }
    let d = BinaryDiff.compare(dataA, dataB)

    if wantsJSON {
        if d.isIdentical {
            print(#"{"result":"identical"}"#)
        } else {
            let first = d.first.map { "\($0.offset)" } ?? "null"
            print("{\"result\":\"differ\",\"regions\":\(d.regions.count),"
                  + "\"differing_bytes\":\(d.differingBytes),\"first_offset\":\(first),"
                  + "\"size_a\":\(d.sizeA),\"size_b\":\(d.sizeB)}")
        }
    } else if d.isIdentical {
        print(t("binary.identical"))
        printRedirects()
    } else {
        // **長さの違いは、箇所の数と別に言う。** 1 バイト挿入で以降が全部ずれた結果を
        // 「全部違う」とだけ出すのは、正しいが役に立たない。
        if d.sizeA != d.sizeB {
            print(t("binary.size", d.sizeA, d.sizeB, d.extraBytes))
        }
        if let first = d.first {
            let where_ = BinaryDiff.hex(first.offset)
            print(d.regions.count == 1
                  ? t("binary.differ.one", where_)
                  : t("binary.differ", d.regions.count, where_))
            print("  " + t("binary.bytes", d.differingBytes, min(d.sizeA, d.sizeB)))
        }
        // **どこまで比べたかを言う。**余りは比べていない。
        printRedirects()
        if d.sizeA != d.sizeB {
            // 共通部分に違いが無いなら、そう言う。**言わないと「長さしか見ていない」のか
            // 「中身も違う」のかが読めない。**
            if d.regions.isEmpty { print("  " + t("binary.common_same", min(d.sizeA, d.sizeB))) }
            else { print("  " + t("binary.common_only", min(d.sizeA, d.sizeB))) }
        }
    }
    exit(d.isIdentical ? 0 : (wantsExitCode ? 1 : 0))
}

let result: ImageComparison
do {
    let ua = try fileURL(for: inputs[0], data: dataA, suffix: "a")
    let ub = try fileURL(for: inputs[1], data: dataB, suffix: "b")
    defer {
        // 一時ファイルは残さない（元がファイルなら消さない）。
        for (input, url) in zip(inputs, [ua, ub]) {
            if case .file = input { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
    result = try compareImages(ua, ub, tolerance: tolerance, ignoreAlpha: ignoreAlpha)
} catch {
    die("\(error)")
}

// **緩めて比べたなら、そう言う。**「同じ」とだけ言うと、何と比べた「同じ」なのかが
// 消える。既定（緩めていない）のときは何も足さない。
var relaxations: [String] = []
if tolerance > 0 { relaxations.append(t("note.tolerance", tolerance)) }
if ignoreAlpha { relaxations.append(t("note.ignore_alpha")) }
let note = relaxations.isEmpty
    ? nil
    : t("note.compared_with", relaxations.joined(separator: t("note.separator")))

switch result {
case .identical:
    if wantsJSON { print(#"{"result":"identical"}"#) }
    else {
        print(t("images.identical"))
        printRedirects()
        if let note { print("  " + note) }
    }
    exit(0)

case .sizeMismatch(let sa, let sb):
    if wantsJSON {
        print(#"{"result":"size_mismatch","a":{"width":\#(sa.width),"height":\#(sa.height)},"b":{"width":\#(sb.width),"height":\#(sb.height)}}"#)
    } else {
        print(t("images.size_mismatch", sa.width, sa.height, sb.width, sb.height))
    }
    exit(wantsExitCode ? 1 : 0)

case .differ(let d):
    if wantsJSON {
        print(#"{"result":"differ","changed":\#(d.changed),"total":\#(d.total),"fraction":\#(d.fraction),"first":{"x":\#(d.first.x),"y":\#(d.first.y)}}"#)
    } else {
        // **数を先に言う。**割合は、丸めて消えないときだけ添える ――
        // 「0.0%」は「同じ」と読めてしまう（PixelDiff.displayPercent）。
        if let pct = d.displayPercent {
            print(t("images.differ", d.changed, d.total, pct))
        } else {
            print(t("images.differ.tiny", d.changed, d.total))
        }
        print(t("images.first", d.first.x, d.first.y))
        printRedirects()
        if let note { print("  " + note) }
    }
    exit(wantsExitCode ? 1 : 0)
}
