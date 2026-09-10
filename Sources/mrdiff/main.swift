import Foundation
import MrDiffCore

// 最初のスライス。**画像 2 枚が違うかどうかと、どこが**を答える。
// 絵は出さない（それは GUI の仕事）。README の1つ目の例に当たる。
//
// **人が読む出力だけ t() を通す。** --json と終了コードは通さない ――
// 訳すと grep を書いた人のスクリプトが日本語環境で壊れる。

let args = Array(CommandLine.arguments.dropFirst())
let wantsJSON = args.contains("--format=json") || args.contains("--json")
let wantsExitCode = args.contains("--exit-code")
let ignoreAlpha = args.contains("--ignore-alpha")
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

guard files.count == 2 else { die(t("error.usage")) }

let a = URL(fileURLWithPath: files[0])
let b = URL(fileURLWithPath: files[1])

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
