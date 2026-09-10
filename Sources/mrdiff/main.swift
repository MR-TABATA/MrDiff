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

guard files.count == 2 else { die(t("error.usage")) }

let a = URL(fileURLWithPath: files[0])
let b = URL(fileURLWithPath: files[1])

// **種類は中身で決める。**拡張子は見ない（.txt でない設定ファイルのほうが多い）。
// テキストが 2 つなら行差分、そうでなければ画像として読む。
let dataA: Data, dataB: Data
do {
    dataA = try readFile(a)
    dataB = try readFile(b)
} catch {
    die("\(error)")
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
    } else {
        // **サマリも同じ口から出す。**print（libc のバッファ）と Out（fd へ直接）を
        // 混ぜると、順番が入れ替わる ―― 実際にサマリが本文の後ろへ回った。
        // 端末に出すときだけページャへ渡す。パイプならそのまま流す。
        let sink = Pager.command(disabled: noPager).flatMap { Pager.start($0) }
        var out = Out(to: sink ?? stdout)
        out.line(t("text.summary", d.changed, d.added, d.removed))
        renderText(d, style: Style(on: useColor), into: &out)
        out.flush()
        Pager.finish()
    }
    exit(d.isIdentical ? 0 : (wantsExitCode ? 1 : 0))
}

// **片方だけテキストなら、比べない。**行と画素は突き合わせられない。
if detectKind(dataA) != detectKind(dataB) { die(t("error.mixed_kinds")) }

let result: ImageComparison
do {
    result = try compareImages(a, b, tolerance: tolerance, ignoreAlpha: ignoreAlpha)
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
        if let note { print("  " + note) }
    }
    exit(wantsExitCode ? 1 : 0)
}
