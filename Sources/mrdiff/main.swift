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

// `--version` は何より先に。訳さない（機械が読むことがある）。
if args.contains("--version") || args.contains("-V") {
    print("mrdiff \(mrdiffVersion)")
    exit(0)
}

// **言語は、訳す前に決める。** `--lang=ja` は `MRDIFF_LANG=ja` と同じ意味で、1 回きりの
// 切り替え用（環境変数より優先）。OS の `LANG` は見ない ―― Localization.swift の線。
// `ja` `en` 以外は断る。黙って英語に落とすと「指定したのに効いていない」に気づけない。
if let raw = args.first(where: { $0.hasPrefix("--lang=") })?.dropFirst("--lang=".count) {
    let lang = String(raw).lowercased()
    guard Lang.supported.contains(lang) else {
        FileHandle.standardError.write(Data("mrdiff: --lang takes en or ja\n".utf8))
        exit(2)
    }
    Lang.select(lang)
}

// **`--help` はスイッチごとに 1 行。**使い方の 1 行（error.usage）は間違えたときに出るもので、
// 何をするスイッチかはここでしか読めない。既定は英語、末尾にもう片方の言語への行き方を書く
// ―― 環境変数を知らない人が日本語の help に辿り着けるように。
if args.contains("--help") || args.contains("-h") {
    print(t("help.usage"))
    print()
    print(t("help.inputs"))
    print()
    let options = CLIOptions.all.map { ($0.usage, $0.helpKey) }
    let width = options.map { $0.0.count }.max() ?? 0
    for (flag, key) in options {
        let pad = String(repeating: " ", count: width - flag.count + 2)
        print("  " + flag + pad + t(key))
    }
    print()
    print(t("help.exit"))
    print()
    print(t(Lang.current == "ja" ? "help.other_lang.en" : "help.other_lang.ja"))
    exit(0)
}

let wantsJSON = args.contains("--format=json") || args.contains("--json")
// `--quiet` は「何も出さず、終了コードだけ返す」。終了コードが答えなので `--exit-code` を含む。
let quiet = args.contains("--quiet") || args.contains("-q")
let wantsExitCode = args.contains("--exit-code") || quiet
let ignoreAlpha = args.contains("--ignore-alpha")
let noPager = args.contains("--no-pager")
let useClipboardFlag = args.contains("--clipboard")
let wantsText = args.contains("--text")
// Terraform の state / plan を比べるときだけ、秘密の値を出す（既定は伏せる）。
let showSecrets = args.contains("--show-secrets")
// `-` だけは標準入力を指す引数なので、つまみとして落とさない。
let files = args.filter { !$0.hasPrefix("-") || $0 == "-" }

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("mrdiff: " + message + "\n").utf8))
    exit(2)
}

// **`--completions bash|zsh|fish`**（`=` でも書ける）。スクリプトを標準出力へ出して終わる。
// Homebrew の `generate_completions_from_executable(bin/"mrdiff", "--completions")` が呼ぶ形。
if let i = args.firstIndex(where: { $0 == "--completions" || $0.hasPrefix("--completions=") }) {
    let shell = args[i].hasPrefix("--completions=")
        ? String(args[i].dropFirst("--completions=".count))
        : (i + 1 < args.count ? args[i + 1] : "")
    guard let script = Completions.script(for: shell) else { die(t("error.bad_completions")) }
    print(script, terminator: "")
    exit(0)
}

// **効かない組み合わせは断る**（黙って片方を無視しない）。`--quiet` は何も出さないので、出力の形を選ぶ
// `--json` と並べられない。標準入力は 1 回しか読めないので、両側に `-` は置けない。
if quiet && wantsJSON { die(t("error.quiet_json")) }
if files.filter({ $0 == "-" }).count > 1 { die(t("error.stdin_twice")) }
// `--quiet`: 画面に出るものは全部、ここで捨てる（エラーは stderr なので残る）。比較の経路ごとに
// 出力を分岐させるより、出口を 1 か所で塞ぐほうが、あとから経路が増えても漏れない。
if quiet {
    let devNull = open("/dev/null", O_WRONLY)
    if devNull >= 0 { dup2(devNull, STDOUT_FILENO); close(devNull) }
}

// `--relative`: エラーに出るファイルのパスを、カレントディレクトリからの相対パスにする（既定は絶対パス）。
PathDisplay.relativeToCurrentDirectory = args.contains("--relative")

// **`--oneline`: 結果を要約の 1 行だけにする。** 要約の行は、比較の種類ごとに、結果を作る場所が
// `headline(…)` で印を付ける（フォルダやアーカイブは要約が最後の行なので、先頭の行を機械的に拾うと
// ずれる）。印が無いまま終わったときだけ、出力の最初の空でない行に戻る。
// 出力は一時ファイルへ逃がしておき、終了時（`exit` は atexit を通る）に 1 行だけ本物の標準出力へ書く。
let oneline = args.contains("--oneline")
if oneline && quiet { die(t("error.quiet_oneline")) }
var onelineHeadline: String? = nil
var onelineRealStdout: Int32 = -1
var onelineCapture: UnsafeMutablePointer<FILE>? = nil
@discardableResult
func headline(_ s: String) -> String {
    if onelineHeadline == nil { onelineHeadline = s }
    return s
}
func finishOneline() {
    guard oneline, let capture = onelineCapture, onelineRealStdout >= 0 else { return }
    fflush(stdout)
    rewind(capture)
    var bytes = [UInt8](), buf = [UInt8](repeating: 0, count: 4096)
    while case let n = fread(&buf, 1, buf.count, capture), n > 0 { bytes += buf[0..<n] }
    let text = String(decoding: bytes, as: UTF8.self)
    let first = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let line = onelineHeadline ?? first.map(String.init) ?? ""
    if !line.isEmpty { let out = Array((line + "\n").utf8); _ = write(onelineRealStdout, out, out.count) }
}
if oneline {
    fflush(stdout)
    onelineRealStdout = dup(STDOUT_FILENO)
    onelineCapture = tmpfile()
    if let c = onelineCapture, onelineRealStdout >= 0 {
        dup2(fileno(c), STDOUT_FILENO)
        atexit { finishOneline() }
    }
}

// **`--tolerance=N` の形だけ受ける。**空白区切り（`--tolerance 2`）を許すと、
// 2 がファイル名の側に落ちて「使い方」が出る ―― 黙って 0 で走るよりはよい。
var tolerance = 0
if let raw = args.first(where: { $0.hasPrefix("--tolerance=") })?
    .dropFirst("--tolerance=".count) {
    guard let n = Int(raw), n >= 0 else { die(t("error.bad_tolerance")) }
    tolerance = n
}

// **`--offset=dx,dy`**：右を左の座標でどこに置くか。ヘッダーが 1 行ぶん違うスクリーンショットは
// そのままでは「全画素が違う」── ずらして重ねれば「中身は同じか」が言える。画像だけ。
var offset: Point? = nil
if let raw = args.first(where: { $0.hasPrefix("--offset=") })?.dropFirst("--offset=".count) {
    let parts = raw.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2, let dx = parts[0], let dy = parts[1] else { die(t("error.bad_offset")) }
    offset = Point(x: dx, y: dy)
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

// **SSH ディレクトリ diff。** ローカルのフォルダと、SSH 越しのリモートのフォルダを
// 両方向で突き合わせる。サイト diff（HTTP・片方向）と違い、リモートも列挙できるので
//   ローカルに無くリモートにある（＝置き忘れ）まで出せる。
//   mrdiff --ssh ./site host:/var/www
if args.contains("--ssh") {
    // 位置引数: ローカルのフォルダ 1 つと、host:path 1 つ。
    var localDirs: [String] = []
    var remotes: [(String, String)] = []
    for arg in files {
        if case .ssh(let h, let p) = Input.parse(arg) { remotes.append((h, p)) }
        else if !arg.hasPrefix("http") { localDirs.append(arg) }
    }
    guard localDirs.count == 1, remotes.count == 1 else { die(t("error.ssh_usage")) }
    let localDir = URL(fileURLWithPath: localDirs[0], isDirectory: true)
    let (host, remotePath) = remotes[0]

    let left: [String: String], right: [String: String]
    do {
        left = try RemoteTree.local(localDir)
        right = try RemoteTree.ssh(host: host, path: remotePath)
    } catch { die("\(error)") }

    let d = TreeDiff.compare(
        leftPaths: left.keys.sorted(), rightPaths: right.keys.sorted(),
        leftHash: { left[$0] }, rightHash: { right[$0] })

    if wantsJSON {
        print(JSONOutput.encode(JSONOutput.tree(d)))
    } else {
        for r in d.changed   { print(t("tree.changed", r.path)) }
        for r in d.onlyLeft  { print(t("tree.only_local", r.path)) }
        for r in d.onlyRight { print(t("tree.only_remote", r.path)) }
        if d.allIdentical {
            print(headline(t("tree.in_sync", d.identical.count)))
        } else {
            print(headline(t("tree.summary", d.changed.count, d.onlyLeft.count, d.onlyRight.count)))
        }
    }
    exit(d.allIdentical ? 0 : (wantsExitCode ? 1 : 0))
}

// **サイト diff。** git 管理下の公開フォルダと、公開中のサイトを突き合わせる。
//   mrdiff --site https://example.com ./site
// git が「意図」の記録。載っているものがサイトにあるべきもの。CLI は無料（GUI が有償）。
if let siteFlagIndex = args.firstIndex(of: "--site") {
    // --site の後ろに URL、位置引数にフォルダ。
    let rest = Array(args[(siteFlagIndex + 1)...])
    guard let base = rest.first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") }),
          let baseURL = URL(string: base) else { die(t("error.site_usage")) }
    let dirs = files.filter { !$0.hasPrefix("http") }
    guard dirs.count == 1 else { die(t("error.site_usage")) }
    let dir = URL(fileURLWithPath: dirs[0], isDirectory: true)

    let tracked: [String]
    do { tracked = try GitFiles.tracked(in: dir) }
    catch { die("\(error)") }
    if tracked.isEmpty { die(t("error.site_empty", PathDisplay.text(dir))) }

    let entries = SiteMap.entries(base: baseURL, relativePaths: tracked)
    let result = SiteDiff.compare(
        entries: entries,
        fetch: { url in
            do {
                let data = try fetch(url, timeout: 30)
                return .got(data)
            } catch let InputError.http(code, _) where code == 404 {
                return .absent
            } catch { return .failed("\(error)") }
        },
        local: { rel in try? Data(contentsOf: dir.appendingPathComponent(rel)) })

    if wantsJSON {
        print(JSONOutput.encode(JSONOutput.site(result)))
    } else {
        for r in result.changed { print(t("site.changed", r.entry.localPath)) }
        for r in result.missing { print(t("site.missing", r.entry.localPath)) }
        for r in result.errored { print(t("site.error", r.entry.localPath)) }
        if result.allInSync {
            print(headline(t("site.in_sync", entries.count)))
        } else {
            print(headline(t("site.summary", result.changed.count, result.missing.count, result.errored.count)))
        }
        // **置き忘れは見つけられないと、必ず言う。** URL に一覧が無いので、
        // 「サイトにあって git に無いもの」は原理的に出せない。
        print("  " + t("site.cannot_find_extras"))
    }
    exit(result.allInSync ? 0 : (wantsExitCode ? 1 : 0))
}

// **手元のフォルダ同士。** `--ssh` はサーバ相手に両方向で比べられるのに、隣のフォルダとは
// 比べられなかった。同じ部品（RemoteTree.local ＋ TreeDiff）を両側に当てるだけ。
// 言うのは「どのファイルが違う／どちらにだけある」まで ―― 中身は、その 2 本を渡せば出る。
//   mrdiff old/ new/
if !useClipboardFlag, files.count == 2 {
    func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }
    let dirA = isDir(files[0]), dirB = isDir(files[1])
    // 片方だけフォルダなら比べない（ファイルとフォルダは突き合わせられない）。
    if dirA != dirB { die(t("error.mixed_dir")) }
    if dirA {
        // 画素のつまみはフォルダには効かない。黙って飲まない。
        if tolerance > 0 || ignoreAlpha { die(t("error.dir_flag")) }
        let left: [String: String], right: [String: String]
        do {
            left = try RemoteTree.local(URL(fileURLWithPath: files[0], isDirectory: true))
            right = try RemoteTree.local(URL(fileURLWithPath: files[1], isDirectory: true))
        } catch { die("\(error)") }
        let d = TreeDiff.compare(
            leftPaths: left.keys.sorted(), rightPaths: right.keys.sorted(),
            leftHash: { left[$0] }, rightHash: { right[$0] })
        if wantsJSON {
            print(JSONOutput.encode(JSONOutput.dir(d)))
        } else {
            for r in d.changed   { print(t("dir.changed", r.path)) }
            for r in d.onlyLeft  { print(t("dir.only_a", r.path)) }
            for r in d.onlyRight { print(t("dir.only_b", r.path)) }
            if d.allIdentical {
                print(headline(t("dir.in_sync", d.identical.count)))
            } else {
                print(headline(t("dir.summary", d.changed.count, d.onlyLeft.count, d.onlyRight.count)))
            }
        }
        exit(d.allIdentical ? 0 : (wantsExitCode ? 1 : 0))
    }
}

// **入れ物は 3 種類**（ファイル・URL・クリップボード）。取ってきた後は同じ道を通る。
let useClipboard = useClipboardFlag
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
var redirectsJSON: [JSONOutput.Redirect] = []
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
            redirectsJSON.append(.init(from: input.label, to: landed.absoluteString))
        }
    }
} catch {
    die("\(error)")
}

/// 飛ばし先の注意書きを出す（人向け）。JSON では `redirected` として同じことを言う。
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

// **Terraform の state / plan は、秘密を伏せる専用の経路で比べる。**片方だけが Terraform だと、普通の
// JSON の経路に落ちて、Terraform 側の秘密が平文で出てしまう。だから、混ざったら比べずに断る。
// （普通の JSON 同士は、これまでどおり。キー名で伏せると普通の `password` という項目まで伏せてしまう。）
let terraformA = parseTerraform(dataA), terraformB = parseTerraform(dataB)
if terraformA != nil || terraformB != nil {
    guard let ta = terraformA, let tb = terraformB, ta.kind == tb.kind else { die(t("error.terraform_mixed")) }
} else if showSecrets {
    die(t("error.show_secrets_flag"))
}

// `--text` は PDF のもの。ほかに渡されたら黙って飲まない（効かないつまみの線）。
if wantsText && !(looksLikePDF(dataA) && looksLikePDF(dataB)) { die(t("error.text_flag")) }
// `--offset` は画像のもの（PDF はページごとの紙なのでずらさない）。
if offset != nil && !(looksLikeImage(dataA) && looksLikeImage(dataB) && !looksLikePDF(dataA)) { die(t("error.offset_flag")) }

if detectKind(dataA) == .text && detectKind(dataB) == .text {
    // **効かないつまみを黙って飲まない。**--tolerance と --ignore-alpha は画素の話で、
    // 行には意味が無い。黙って無視すると「指定したのに効いていない」に気づけない。
    if tolerance > 0 || ignoreAlpha { die(t("error.image_only_flag")) }

    if let ta = terraformA, let tb = terraformB {
        let d = compareTerraform(ta, tb, showSecrets: showSecrets)
        let name = d.kind == .state ? "state" : "plan"
        if wantsJSON {
            print(JSONOutput.encode(JSONOutput.terraform(d, redirects: redirectsJSON)))
        } else if d.isIdentical {
            print(headline(t("tf.\(name).identical")))
            printRedirects()
        } else {
            let sink = Pager.command(disabled: noPager).flatMap { Pager.start($0) }
            var out = Out(to: sink ?? stdout)
            out.line(headline(t("tf.\(name).summary", d.changed, d.added, d.removed)))
            for line in redirects { out.line("  " + line) }
            renderTerraform(d, hiddenNote: !showSecrets, style: Style(on: useColor), into: &out)
            out.flush()
            Pager.finish()
        }
        exit(d.isIdentical ? 0 : (wantsExitCode ? 1 : 0))
    }

    // **JSON／YAML として両方読めたら、構造で比べる。**「同じでもキーの並びが違う」
    // を差分に出さないための線（README が挙げていた穴）。どちらかが読めなければ
    // （崩れた YAML、対応していない構文、1 単語だけの英文）黙って行 diff に戻る ――
    // 「浅くてもいいが、間違ってはいけない」を、パーサが投げたときにも守る。
    // 両側の形式（json/yaml）が食い違っても比較はできる ―― `kind` は A 側の形式で言う。
    if let (va, formatA) = parseStructured(dataA), let (vb, _) = parseStructured(dataB) {
        let d = compareStructured(va, vb)
        if wantsJSON {
            print(JSONOutput.encode(JSONOutput.structured(d, format: formatA, redirects: redirectsJSON)))
        } else if d.isIdentical {
            print(headline(t("structured.identical")))
            printRedirects()
        } else {
            let sink = Pager.command(disabled: noPager).flatMap { Pager.start($0) }
            var out = Out(to: sink ?? stdout)
            out.line(headline(t("structured.summary", d.changed, d.added, d.removed)))
            for line in redirects { out.line("  " + line) }
            renderStructured(d, style: Style(on: useColor), into: &out)
            out.flush()
            Pager.finish()
        }
        exit(d.isIdentical ? 0 : (wantsExitCode ? 1 : 0))
    }

    let d = compareText(TextSource(data: dataA), TextSource(data: dataB))
    // **改行コードが違うなら、そう言う。**CRLF と LF は同じ扱いで diff には出ないので、黙っていると
    // 「バイトは違うのに No differences」になる。CR だけの区切りは行に切らない、とも添える。
    let eol = LineEnding.difference(dataA, dataB)
    var eolNote: String? = nil
    if let e = eol {
        var s = t("note.line_endings", e.a.rawValue, e.b.rawValue)
        if e.a == .cr || e.b == .cr { s += " " + t("note.line_endings.cr") }
        eolNote = s
    }
    if wantsJSON {
        print(JSONOutput.encode(JSONOutput.text(d, redirects: redirectsJSON, lineEndings: eol)))
    } else if d.isIdentical {
        print(headline(t("text.identical")))
        printRedirects()
        if let eolNote { print("  " + eolNote) }
    } else {
        // **サマリも同じ口から出す。**print（libc のバッファ）と Out（fd へ直接）を
        // 混ぜると、順番が入れ替わる ―― 実際にサマリが本文の後ろへ回った。
        // 端末に出すときだけページャへ渡す。パイプならそのまま流す。
        let sink = Pager.command(disabled: noPager).flatMap { Pager.start($0) }
        var out = Out(to: sink ?? stdout)
        out.line(headline(t("text.summary", d.changed, d.added, d.removed)))
        for line in redirects { out.line("  " + line) }
        if let eolNote { out.line("  " + eolNote) }
        renderText(d, style: Style(on: useColor), into: &out)
        out.flush()
        Pager.finish()
    }
    exit(d.isIdentical ? 0 : (wantsExitCode ? 1 : 0))
}

// **片方だけテキストなら、比べない。**行と画素は突き合わせられない。
if detectKind(dataA) != detectKind(dataB) { die(t("error.mixed_kinds")) }

// **PDF は画像より先に聞く。** ImageIO は PDF を「1 ページ目だけの画像」として読んで
// しまうので、後ろに回すと複数ページの PDF が 1 枚の絵として比べられる。
// ページごとに描いて画素で比べ、場所は紙の単位（mm）で言う。片方だけ PDF なら比べない。
let pdfA = looksLikePDF(dataA), pdfB = looksLikePDF(dataB)
if pdfA != pdfB { die(t("error.mixed_pdf")) }
if pdfA {
    // 描くときに白で潰すので、透明度は見るものが無い。黙って飲まない（画像の線と同じ）。
    if ignoreAlpha { die(t("error.pdf_alpha_flag")) }
    // **文字も抜く。** 見た目の差は「どこが」までで、契約書は「どの文言が」を知りたい。
    // 両方に文字があれば行 diff に掛け、--text ならそれを見せる。無ければ見た目だけ
    // （スキャンした PDF）で、そのことを言う。
    let textDiff: TextDiff? = {
        guard let ta = PDFText.text(in: dataA), let tb = PDFText.text(in: dataB) else { return nil }
        return compareText(TextSource(data: Data(ta.utf8)), TextSource(data: Data(tb.utf8)))
    }()
    if wantsText {
        guard let td = textDiff else { die(t("error.pdf_no_text")) }
        if wantsJSON {
            var o = JSONOutput.text(td, redirects: redirectsJSON)
            o["kind"] = "pdf-text"
            print(JSONOutput.encode(o))
        } else if td.isIdentical {
            print(headline(t("pdf.text.identical", td.left.lines.count)))
            printRedirects()
        } else {
            let sink = Pager.command(disabled: noPager).flatMap { Pager.start($0) }
            var out = Out(to: sink ?? stdout)
            out.line(headline(t("pdf.text.summary", td.changed, td.added, td.removed)))
            for line in redirects { out.line("  " + line) }
            renderText(td, style: Style(on: useColor), into: &out)
            out.flush()
            Pager.finish()
        }
        exit(td.isIdentical ? 0 : (wantsExitCode ? 1 : 0))
    }

    let d: PDFComparison
    do { d = try comparePDFs(dataA, dataB, tolerance: tolerance) }
    catch { die("\(error)") }

    if wantsJSON {
        print(JSONOutput.encode(JSONOutput.pdf(d, tolerance: tolerance, text: textDiff, redirects: redirectsJSON)))
        exit(d.isIdentical ? 0 : (wantsExitCode ? 1 : 0))
    }
    if d.isIdentical {
        print(headline(t("pdf.identical", d.pagesA)))
        printRedirects()
        if tolerance > 0 { print("  " + t("note.compared_with", t("note.tolerance", tolerance))) }
        exit(0)
    }
    // **ページ数の違いは、中身の違いと別に言う。**共通のページに違いが無いなら、そう言う。
    let common = d.pages.count
    if d.pagesA != d.pagesB { print(t("pdf.page_count", d.pagesA, d.pagesB)) }
    let differing = d.differingPages
    if differing.isEmpty {
        print(headline(t("pdf.common_same", common)))
    } else {
        print(headline(t("pdf.summary", differing.count, common)))
    }
    // 単位は mm。72 dpi で 1 px ≈ 0.35 mm なので、整数で言えば十分。
    let mm = { (v: Double) -> String in String(Int(v.rounded())) }
    for (i, page) in d.pages.enumerated() {
        switch page {
        case .identical:
            continue
        case .sizeMismatch(let a, let b):
            print(t("pdf.page.size_mismatch", i + 1, mm(a.width), mm(a.height), mm(b.width), mm(b.height)))
        case .differ(let pd):
            print(pd.regions.count == 1
                  ? t("pdf.page.differ.one", i + 1)
                  : t("pdf.page.differ", i + 1, pd.regions.count))
            for r in pd.regions {
                print("     " + t("pdf.region", mm(r.top), mm(r.left), mm(r.width), mm(r.height)))
            }
        }
    }
    // 余ったページは比べていない。どちらにだけあるかを、番号で言う。
    if d.pagesA != d.pagesB {
        let more = d.pagesA > d.pagesB ? "A" : "B"
        let from = common + 1, to = max(d.pagesA, d.pagesB)
        print(from == to ? t("pdf.only.one", from, more) : t("pdf.only", from, to, more))
    }
    printRedirects()
    // 文字の差は別に言う。**見た目が違って文字が同じ**（フォントの差し替え、再エンコード）と、
    // 文言が変わったのは、校正では別の事件。
    if let td = textDiff {
        if td.isIdentical { print("  " + t("pdf.text.same")) }
        else { print("  " + t("pdf.text.hint", td.changed + td.added + td.removed)) }
    } else {
        print("  " + t("pdf.text.none"))
    }
    print("  " + t("pdf.rendered", d.dpi))
    if tolerance > 0 { print("  " + t("note.compared_with", t("note.tolerance", tolerance))) }
    exit(wantsExitCode ? 1 : 0)
}

// **zip は中身をフォルダとして比べる。** docx / xlsx / pptx / EPUB / Sketch は拡張子が
// 違うだけで中は zip なので、「中のどのファイルが変わったか」がそのまま答えになる。
// 両方に Word の本文があれば、そこは段落の行 diff にする ―― 契約書・仕様書の版比較で
// 知りたいのは「どの段落の文言が」で、XML の差分ではない。
let zipA = ZipArchive.looksLikeZip(dataA), zipB = ZipArchive.looksLikeZip(dataB)
if zipA != zipB { die(t("error.mixed_zip")) }
if zipA {
    if tolerance > 0 || ignoreAlpha { die(t("error.pixel_flag")) }
    guard let za = ZipArchive(data: dataA), let zb = ZipArchive(data: dataB) else { die(t("error.bad_zip")) }
    let fa = za.fingerprints, fb = zb.fingerprints
    let parts = TreeDiff.compare(leftPaths: fa.keys.sorted(), rightPaths: fb.keys.sorted(),
                                 leftHash: { fa[$0] }, rightHash: { fb[$0] })

    if let ta = DocxText.text(in: za), let tb = DocxText.text(in: zb) {
        // Word。本文は段落で比べ、本文以外（書式・画像・プロパティ）は数だけ言う。
        let d = compareText(TextSource(data: Data(ta.utf8)), TextSource(data: Data(tb.utf8)))
        let others = parts.rows.filter { $0.status != .identical && $0.path != DocxText.bodyPath }.count
        if wantsJSON {
            print(JSONOutput.encode(JSONOutput.docx(d, otherPartsChanged: others, redirects: redirectsJSON)))
        } else if d.isIdentical {
            print(headline(t("docx.identical", d.left.lines.count)))
            if others > 0 { print("  " + t("docx.others", others)) }
            printRedirects()
        } else {
            let sink = Pager.command(disabled: noPager).flatMap { Pager.start($0) }
            var out = Out(to: sink ?? stdout)
            out.line(headline(t("docx.summary", d.changed, d.added, d.removed)))
            if others > 0 { out.line("  " + t("docx.others", others)) }
            for line in redirects { out.line("  " + line) }
            renderText(d, style: Style(on: useColor), into: &out)
            out.flush()
            Pager.finish()
        }
        let same = d.isIdentical && others == 0
        exit(same ? 0 : (wantsExitCode ? 1 : 0))
    }

    if wantsJSON {
        print(JSONOutput.encode(JSONOutput.archive(parts, redirects: redirectsJSON)))
    } else {
        for r in parts.changed   { print(t("dir.changed", r.path)) }
        for r in parts.onlyLeft  { print(t("dir.only_a", r.path)) }
        for r in parts.onlyRight { print(t("dir.only_b", r.path)) }
        if parts.allIdentical {
            print(headline(t("archive.in_sync", parts.identical.count)))
        } else {
            print(headline(t("archive.summary", parts.changed.count, parts.onlyLeft.count, parts.onlyRight.count)))
        }
        printRedirects()
    }
    exit(parts.allIdentical ? 0 : (wantsExitCode ? 1 : 0))
}

// **フォントは文字ごとに字形を描いて比べる。** バイトではテーブルを書き出し直しただけで
// 全部違う。両方が持つ文字を同じ枠に描いて突き合わせ、片方にしか無い文字は増減として言う。
let fontA = looksLikeFont(dataA), fontB = looksLikeFont(dataB)
if fontA != fontB { die(t("error.mixed_font")) }
if fontA {
    if tolerance > 0 || ignoreAlpha { die(t("error.pixel_flag")) }
    let r: FontComparison
    do { r = try compareFonts(dataA, dataB) } catch { die("\(error)") }
    if wantsJSON {
        print(JSONOutput.encode(JSONOutput.font(r, redirects: redirectsJSON)))
        exit(r.isIdentical ? 0 : (wantsExitCode ? 1 : 0))
    }
    if r.isIdentical {
        print(headline(t("font.identical", r.compared)))
    } else {
        if r.changed.isEmpty {
            print(headline(t("font.same_glyphs", r.compared)))
        } else {
            print(headline(t("font.differ", r.changed.count, r.compared)))
            print("  " + t("font.first", describeCodepoint(r.changed[0])))
        }
        if !r.onlyA.isEmpty { print("  " + t("font.only_a", r.onlyA.count, describeCodepoint(r.onlyA[0]))) }
        if !r.onlyB.isEmpty { print("  " + t("font.only_b", r.onlyB.count, describeCodepoint(r.onlyB[0]))) }
    }
    if r.nameA != r.nameB { print("  " + t("font.name", r.nameA, r.nameB)) }
    if let va = r.versionA, let vb = r.versionB, va != vb { print("  " + t("font.version", va, vb)) }
    printRedirects()
    print("  " + t("font.rendered", r.cell))
    exit(r.isIdentical ? 0 : (wantsExitCode ? 1 : 0))
}

// **SQLite は、スキーマ（テーブル・列・索引・ビュー・トリガ）を比べる。**行のデータは比べない（先にスキーマ
// だけ。行は主キー・大きなテーブルで重い）。だから、スキーマが同じでバイトが違うときは、そう言う。
// 読めなかった（暗号化・壊れている）ときは、これまでどおりバイナリとして比べ、そのことを言う。
let sqliteA = looksLikeSQLite(dataA), sqliteB = looksLikeSQLite(dataB)
if sqliteA != sqliteB { die(t("error.mixed_sqlite")) }
if sqliteA {
    if tolerance > 0 || ignoreAlpha { die(t("error.pixel_flag")) }
    let ua = try? fileURL(for: inputs[0], data: dataA, suffix: "a.db")
    let ub = try? fileURL(for: inputs[1], data: dataB, suffix: "b.db")
    defer {
        for (input, url) in zip(inputs, [ua, ub]) {
            if case .file = input { continue }
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }
    do {
        guard let ua, let ub else { throw SQLiteError.cannotOpen("temporary file") }
        let d = compareSQLiteSchemas(try readSQLiteSchema(at: ua), try readSQLiteSchema(at: ub))
        let bytesDiffer = dataA != dataB
        let same = d.isIdentical && !bytesDiffer
        if wantsJSON {
            print(JSONOutput.encode(JSONOutput.sqlite(d, bytesDiffer: bytesDiffer)))
        } else if same {
            print(headline(t("sqlite.identical")))
            printRedirects()
        } else if d.isIdentical {
            print(headline(t("sqlite.schema_same_bytes_differ")))
            printRedirects()
        } else {
            let counts = (
                d.tablesChanged.count + d.indexesChanged.count + d.viewsChanged.count + d.triggersChanged.count,
                d.tablesAdded.count + d.indexesAdded.count + d.viewsAdded.count + d.triggersAdded.count,
                d.tablesRemoved.count + d.indexesRemoved.count + d.viewsRemoved.count + d.triggersRemoved.count)
            let sink = Pager.command(disabled: noPager).flatMap { Pager.start($0) }
            var out = Out(to: sink ?? stdout)
            out.line(headline(t("sqlite.summary", counts.0, counts.1, counts.2)))
            for line in redirects { out.line("  " + line) }
            renderSQLite(d, style: Style(on: useColor), into: &out)
            out.flush()
            Pager.finish()
        }
        exit(same ? 0 : (wantsExitCode ? 1 : 0))
    } catch {
        // 読めなかった。黙ってバイナリに落とさず、落としたと言う。
        redirects.append(t("note.sqlite_unreadable", "\(error)"))
    }
}

// テキストでないものは、**画像として読めるかどうか**でさらに分ける。拡張子は見ない。
// 片方だけ画像なら比べない（画素と生バイトも突き合わせられない）。
let imageA = looksLikeImage(dataA), imageB = looksLikeImage(dataB)
if imageA != imageB { die(t("error.mixed_kinds")) }

if !imageA {
    if tolerance > 0 || ignoreAlpha { die(t("error.image_only_flag")) }
    let d = BinaryDiff.compare(dataA, dataB)

    if wantsJSON {
        print(JSONOutput.encode(JSONOutput.binary(d, redirects: redirectsJSON)))
    } else if d.isIdentical {
        print(headline(t("binary.identical")))
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
/// 全体の色の差（B − A の平均）。違ったときだけ人向けに添える。
var tone: ToneDifference?
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
    let ia = try loadImage(at: ua), ib = try loadImage(at: ub)
    if let offset {
        // ずらして、重なる範囲だけ。寸法が違っても比べる。
        result = comparePixels(a: ia.pixels, sizeA: ia.size, b: ib.pixels, sizeB: ib.size,
                               bytesPerPixel: ia.bytesPerPixel, offset: offset, tolerance: tolerance, ignoreAlpha: ignoreAlpha)
    } else {
        result = comparePixels(a: ia.pixels, sizeA: ia.size, b: ib.pixels, sizeB: ib.size,
                               bytesPerPixel: ia.bytesPerPixel, tolerance: tolerance, ignoreAlpha: ignoreAlpha)
    }
    tone = toneDifference(a: ia.pixels, sizeA: ia.size, b: ib.pixels, sizeB: ib.size, bytesPerPixel: ia.bytesPerPixel)
} catch {
    die("\(error)")
}

// **緩めて比べたなら、そう言う。**「同じ」とだけ言うと、何と比べた「同じ」なのかが
// 消える。既定（緩めていない）のときは何も足さない。
var relaxations: [String] = []
if tolerance > 0 { relaxations.append(t("note.tolerance", tolerance)) }
if ignoreAlpha { relaxations.append(t("note.ignore_alpha")) }
// ずらしは「緩め」ではなく「置き方」なので、別の 1 行で言う。重なった範囲しか比べていない
// ので数も（identical のときは重なりが無かった可能性もある）。
let offsetNote: String? = offset.map { o in
    if case .differ(let d) = result { return t("note.offset", o.x, o.y, d.total) }
    return t("note.offset.plain", o.x, o.y)
}
let note = relaxations.isEmpty
    ? nil
    : t("note.compared_with", relaxations.joined(separator: t("note.separator")))

if wantsJSON {
    print(JSONOutput.encode(JSONOutput.image(result, tolerance: tolerance, ignoreAlpha: ignoreAlpha,
                                             offset: offset, tone: tone, redirects: redirectsJSON)))
    if case .identical = result { exit(0) }
    exit(wantsExitCode ? 1 : 0)
}

switch result {
case .identical:
    print(headline(t("images.identical")))
    printRedirects()
    if let offsetNote { print("  " + offsetNote) }
    if let note { print("  " + note) }
    exit(0)

case .sizeMismatch(let sa, let sb):
    print(headline(t("images.size_mismatch", sa.width, sa.height, sb.width, sb.height)))
    exit(wantsExitCode ? 1 : 0)

case .differ(let d):
    // **数を先に言う。**割合は、丸めて消えないときだけ添える ――
    // 「0.0%」は「同じ」と読めてしまう（PixelDiff.displayPercent）。
    if let pct = d.displayPercent {
        print(headline(t("images.differ", d.changed, d.total, pct)))
    } else {
        print(headline(t("images.differ.tiny", d.changed, d.total)))
    }
    print(t("images.first", d.first.x, d.first.y))
    printRedirects()
    if let offsetNote { print("  " + offsetNote) }
    if let note { print("  " + note) }
    // **全体が同じ向きにずれているなら、そう言う。**「44% が違う」の写真が、実は全画素が
    // +20 明るいだけだった ── 数だけでは圧縮のノイズとも細工とも区別がつかない。
    if let tone, abs(tone.overall) >= 2 {
        let ch = tone.mean.map { String(format: "%+.0f", $0) }.joined(separator: " ")
        print("  " + t(tone.overall > 0 ? "images.tone.brighter" : "images.tone.darker", abs(Int(tone.overall.rounded())), ch))
    }
    // **既定は変えない。代わりに緩め方を教える。**「見た目は同じなのに違う」と出た人が、
    // どこまで緩めれば同じになるかをここで知る。緩めた上でまだ違うときも、その先の値を言う。
    print("  " + t("images.gap", d.maxGap, d.maxGap))
    exit(wantsExitCode ? 1 : 0)
}
