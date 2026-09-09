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
let files = args.filter { !$0.hasPrefix("-") }

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("mrdiff: " + message + "\n").utf8))
    exit(2)
}

guard files.count == 2 else { die(t("error.usage")) }

let a = URL(fileURLWithPath: files[0])
let b = URL(fileURLWithPath: files[1])

let result: ImageComparison
do {
    result = try compareImages(a, b)
} catch {
    die("\(error)")
}

func percent(_ f: Double) -> String { String(format: "%.1f", f * 100) }

switch result {
case .identical:
    if wantsJSON { print(#"{"result":"identical"}"#) }
    else { print(t("images.identical")) }
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
        print(t("images.differ", percent(d.fraction), d.changed, d.total))
        print(t("images.first", d.first.x, d.first.y))
    }
    exit(wantsExitCode ? 1 : 0)
}
