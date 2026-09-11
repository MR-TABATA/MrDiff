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

    /// 引数 1 つを入れ物に読み替える。
    ///
    /// **`http://` と `https://` だけを URL として扱う。** `file://` も `ftp://` も
    /// ファイル扱いにしない ―― 黙って別のものを取りに行くより、開けないと言うほうがよい。
    public static func parse(_ argument: String) -> Input {
        if argument.hasPrefix("http://") || argument.hasPrefix("https://"),
           let u = URL(string: argument) {
            return .url(u)
        }
        return .file(URL(fileURLWithPath: argument))
    }

    /// 画面に出す名前。
    public var label: String {
        switch self {
        case .file(let u):  return u.lastPathComponent
        case .url(let u):   return u.absoluteString
        case .clipboard:    return t("input.clipboard")
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
        }
    }
}

public enum InputError: Error, CustomStringConvertible {
    case http(Int, URL)
    case network(String, URL)
    case emptyClipboard
    case clipboardUnavailable

    public var description: String {
        switch self {
        case .http(let code, let u):    return t("error.http_status", code, u.absoluteString)
        case .network(let why, let u):  return t("error.fetch_failed", u.absoluteString, why)
        case .emptyClipboard:           return t("error.empty_clipboard")
        case .clipboardUnavailable:     return t("error.no_clipboard")
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
