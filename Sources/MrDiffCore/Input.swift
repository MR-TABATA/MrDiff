import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// 比べる 2 つの**入れ物**。ファイル・URL・クリップボードの違いはここで吸収する。
///
/// ## 比較の本体は増やさない
///
/// URL を足してもクリップボードを足しても、**取ってきた後は同じ道**を通る ――
/// テキストなら行差分、画像なら画素、それ以外はバイナリ。
/// 入口が増えるだけで、答え方は増えない。
///
/// ## 名前を持たせる理由
///
/// エラーや「長さが違う」を出すときに **どちら側の話か**が要る。URL は長いので、
/// そのまま出すと読めない ―― けれど短くすると別の URL と区別が付かなくなるので、
/// **縮めずにそのまま出す**（読みにくさより、取り違えのほうが困る）。
public enum Input {
    case file(URL)
    case url(URL)
    case clipboard
    /// `host:/path`。**scp で取る**（認証は OS の ssh に任せる）。
    case ssh(host: String, path: String)

    /// 引数 1 つを入れ物に読み替える。
    ///
    /// **`http://` と `https://` だけを URL として扱う。** `file://` も `ftp://` も
    /// ファイル扱いにしない ―― 黙って別のものを取りに行くより、開けないと言うほうがよい。
    public static func parse(_ argument: String) -> Input {
        if argument.hasPrefix("http://") || argument.hasPrefix("https://"),
           let u = URL(string: argument) {
            return .url(u)
        }
        if let ssh = parseSSH(argument) { return ssh }
        return .file(URL(fileURLWithPath: argument))
    }

    /// `host:/path` / `user@host:path` を見分ける。**Windows のドライブ文字（`C:\...`）と
    /// 取り違えない**よう、`:` の前が 1 文字なら SSH にしない（が、対象は macOS なので主眼は
    /// 「相対パスに `:` が入っただけ」を SSH と誤らないこと）。
    ///
    /// SSH と見なす条件: `:` があり、その前に `/` が無く（`./a:b` を弾く）、`:` の前が
    /// **ホスト名として妥当**（英数・`.`・`-`・`@`・`_`）であること。
    static func parseSSH(_ arg: String) -> Input? {
        // `scheme://…`（file / ftp / s3 など）は SSH ではない。**`://` を先に弾く。**
        // http(s) は parse で処理済みだが、それ以外のスキームも「別のもの」なので
        // scp で取りに行かない ―― 黙って ssh を走らせるより、ファイル扱いで「開けない」が正。
        if arg.contains("://") { return nil }
        guard let colon = arg.firstIndex(of: ":") else { return nil }
        let hostPart = String(arg[..<colon])
        let path = String(arg[arg.index(after: colon)...])
        guard !hostPart.isEmpty, !path.isEmpty else { return nil }
        // ホスト部に `/` があれば URL かパス。
        if hostPart.contains("/") { return nil }
        // ホスト部が英数と @ . - _ だけからなること。
        let ok = hostPart.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.@-_").contains($0)
        }
        // 1 文字のホストは、ドライブ文字らしさより実在ホストらしさが薄い＝SSH にしない。
        guard ok, hostPart.count >= 2 else { return nil }
        return .ssh(host: hostPart, path: path)
    }

    /// 画面に出す名前。
    public var label: String {
        switch self {
        case .file(let u):  return u.lastPathComponent
        case .url(let u):   return u.absoluteString
        case .clipboard:    return t("input.clipboard")
        case .ssh(let h, let p): return "\(h):\(p)"
        }
    }

    /// 中身を取る。
    public func read(timeout: TimeInterval = 30) throws -> Data {
        try readDetailed(timeout: timeout).data
    }

    /// 中身と、**飛ばされた先**（URL のときだけ・同じなら nil）。
    public func readDetailed(timeout: TimeInterval = 30) throws -> Fetched {
        switch self {
        case .file(let u):  return Fetched(data: try readFile(u), finalURL: nil)
        case .url(let u):   return try fetchDetailed(u, timeout: timeout)
        case .clipboard:    return Fetched(data: try readClipboard(), finalURL: nil)
        case .ssh(let h, let p): return Fetched(data: try scpFetch(host: h, path: p), finalURL: nil)
        }
    }
}

public enum InputError: Error, CustomStringConvertible {
    case http(Int, URL)
    case network(String, URL)
    case emptyClipboard
    case clipboardUnavailable
    case sshFailed(String, String)   // (host:path, stderr)

    public var description: String {
        switch self {
        case .http(let code, let u):    return t("error.http_status", code, u.absoluteString)
        case .network(let why, let u):  return t("error.fetch_failed", u.absoluteString, why)
        case .emptyClipboard:           return t("error.empty_clipboard")
        case .clipboardUnavailable:     return t("error.no_clipboard")
        case .sshFailed(let target, let why): return t("error.ssh_failed", target, why)
        }
    }
}

// MARK: - URL

/// URL の中身を取る。**そのまま取るだけ。**
///
/// JavaScript は動かさないし、描画もしない ―― 取れるのは**サーバが返したそのもの**。
/// 「ブラウザで見た画面」と違うことがあるが、**それはこの道具の答えの外**で、
/// ごまかすと「違わないはずが違う」と言い出す道具になる。
///
/// 画像を返す URL なら画像として比べられる（読んだ後は同じ道を通るため）。
///
/// ## 飛ばされたら、そう言う
///
/// リダイレクトは追う（追わないと、ほとんどのサイトで本文が取れない）。ただし
/// **指定した URL と、実際に中身を取った URL が違うなら、それは言う** ――
/// `https://example.com` と打って `https://www.example.com/ja/` を比べていた、が
/// 黙って起きるのは、画像で「緩めて比べたならそう言う」としているのと同じ問題。
public func fetch(_ url: URL, timeout: TimeInterval = 30) throws -> Data {
    try fetchDetailed(url, timeout: timeout).data
}

/// 中身と、**実際に取れた URL**。
public struct Fetched {
    public let data: Data
    /// リダイレクトの果て。指定した URL と同じなら nil。
    public let finalURL: URL?
}

public func fetchDetailed(_ url: URL, timeout: TimeInterval = 30) throws -> Fetched {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    // **名乗る。** 名乗らないと弾くサーバがあり、その 403 は利用者には理由が分からない。
    request.setValue("mrdiff", forHTTPHeaderField: "User-Agent")
    // キャッシュを使わない。**比べる相手が古い写しでは意味が無い。**
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

    var result: Result<Fetched, InputError>!
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { done.signal() }
        if let error {
            result = .failure(.network(error.localizedDescription, url))
            return
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            result = .failure(.http(http.statusCode, url))
            return
        }
        let landed = response?.url
        let moved = (landed.map { !sameDestination($0, url) } ?? false) ? landed : nil
        result = .success(Fetched(data: data ?? Data(), finalURL: moved))
    }.resume()
    done.wait()
    return try result.get()
}

/// 同じ行き先か。
///
/// **末尾のスラッシュだけの違いは、飛ばされたと言わない。** `https://example.com` を
/// 打つと `https://example.com/` が返る ―― これはリダイレクトではなく、空のパスが
/// 補われただけ。これを「飛ばされました」と出すと、**本物の警告まで信用されなくなる。**
public func sameDestination(_ a: URL, _ b: URL) -> Bool {
    func normalized(_ u: URL) -> String {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else {
            return u.absoluteString
        }
        if c.path.isEmpty { c.path = "/" }
        return c.string ?? u.absoluteString
    }
    return normalized(a) == normalized(b)
}

// MARK: - クリップボード

/// クリップボードの中身。**`pbpaste` を呼ばずに自分で読む**（外部コマンドに依存しない）。
///
/// 文字が入っていれば文字として、無ければ**画像として**取る ―― スクリーンショットを
/// 撮って「さっきの画像と違う？」が、この機能のいちばん多い使い道だと見ている。
public func readClipboard() throws -> Data {
    #if canImport(AppKit)
    let board = NSPasteboard.general
    if let s = board.string(forType: .string), !s.isEmpty {
        return Data(s.utf8)
    }
    // 画像は PNG → TIFF の順で見る（PNG のほうが素直に比べられる）。
    for type in [NSPasteboard.PasteboardType.png, .tiff] {
        if let d = board.data(forType: type), !d.isEmpty { return d }
    }
    throw InputError.emptyClipboard
    #else
    throw InputError.clipboardUnavailable
    #endif
}


// MARK: - SSH

/// リモートの 1 ファイルを取る。**`scp` を呼ぶだけ** ―― 鍵・~/.ssh/config・エージェントは
/// OS の ssh に任せる。パスワードやポートを自分で受け取らない（そこがバグと事故の温床）。
public func scpFetch(host: String, path: String) throws -> Data {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mrdiff-scp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // `-B`＝パスワードを対話で聞かない（CLI が固まらない。鍵が無ければ即失敗させる）。
    // `-p`＝パーミッションと時刻を保つ（比較には使わないが scp の作法）。
    p.arguments = ["scp", "-Bp", "\(host):\(path)", tmp.path]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = Pipe()
    do { try p.run() } catch { throw InputError.sshFailed("\(host):\(path)", "scp not found") }
    let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw InputError.sshFailed("\(host):\(path)",
                                   errText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return try Data(contentsOf: tmp)
}
