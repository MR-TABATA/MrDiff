import Foundation

#if canImport(CoreText)
import CoreText
import CoreGraphics

/// フォントの比較。**文字ごとに字形を描いて、画素で比べる。**
///
/// OTF / TTF をバイトで比べると、テーブルを書き出し直しただけで全部違う。
/// 書体を作る人・買った人が知りたいのは「どの字形が変わったか」なので、両方が持つ
/// 文字を 1 つずつ同じ枠に描いて突き合わせ、違った文字を並べる。片方にしか無い文字は
/// 「増えた／減った」として別に言う ―― PDF のページ数と同じ扱い。
///
/// 描くのは CoreText（Apple のプラットフォームにしか無い。ImageIO と同じ縛り）。
/// 同じ描き手で描くので、字形が同じなら 1 画素も違わない。
public struct FontComparison: Equatable, Sendable {
    public let nameA: String
    public let nameB: String
    public let versionA: String?
    public let versionB: String?
    /// それぞれが持つ文字の数。
    public let charactersA: Int
    public let charactersB: Int
    /// 両方が持ち、描いて比べた文字の数。
    public let compared: Int
    /// 描いて違った文字（コードポイント、昇順）。
    public let changed: [UInt32]
    /// 片方にしか無い文字（昇順）。
    public let onlyA: [UInt32]
    public let onlyB: [UInt32]
    /// 1 文字の枠の大きさ（px）。
    public let cell: Int

    public var isIdentical: Bool { changed.isEmpty && onlyA.isEmpty && onlyB.isEmpty }
}

public enum FontLoadError: Error, CustomStringConvertible {
    case notAFont
    public var description: String { t("error.not_a_font") }
}

/// 中身がフォントか。**拡張子は見ない。**OTF（`OTTO`）、TTF（`0x00010000` / `true`）、
/// TTC（`ttcf`）。WOFF は CoreText が直接は読まないので、ここでは受けない。
public func looksLikeFont(_ data: Data) -> Bool {
    guard data.count >= 4 else { return false }
    let sig = [UInt8](data.prefix(4))
    return sig == [0x4F, 0x54, 0x54, 0x4F]     // OTTO
        || sig == [0x00, 0x01, 0x00, 0x00]     // TrueType
        || sig == [0x74, 0x72, 0x75, 0x65]     // true
        || sig == [0x74, 0x74, 0x63, 0x66]     // ttcf
}

/// フォント 2 つを比べる。`cell` は 1 文字の枠（px）。既定 48 ―― 太さや形の違いは
/// 十分に出て、CJK の 2 万字でも数秒で終わる。
public func compareFonts(_ a: Data, _ b: Data, cell: Int = 48) throws -> FontComparison {
    guard let fa = LoadedFont(data: a, size: CGFloat(cell) * 0.6),
          let fb = LoadedFont(data: b, size: CGFloat(cell) * 0.6) else { throw FontLoadError.notAFont }

    let common = fa.characters.intersection(fb.characters).sorted()
    let onlyA = fa.characters.subtracting(fb.characters).sorted()
    let onlyB = fb.characters.subtracting(fa.characters).sorted()

    let ra = GlyphRenderer(cell: cell), rb = GlyphRenderer(cell: cell)
    var changed: [UInt32] = []
    for c in common {
        if ra.render(c, with: fa) != rb.render(c, with: fb) { changed.append(c) }
    }
    return FontComparison(nameA: fa.name, nameB: fb.name, versionA: fa.version, versionB: fb.version,
                          charactersA: fa.characters.count, charactersB: fb.characters.count,
                          compared: common.count, changed: changed, onlyA: onlyA, onlyB: onlyB, cell: cell)
}

/// コードポイントを人に見せる形（`あ U+3042`）。制御文字や結合文字は U+ だけ。
public func describeCodepoint(_ c: UInt32) -> String {
    let hex = String(format: "U+%04X", c)
    guard let s = UnicodeScalar(c), s.properties.generalCategory != .control,
          s.properties.generalCategory != .format, !s.properties.isWhitespace,
          s.properties.generalCategory != .nonspacingMark else { return hex }
    return "\(Character(s)) \(hex)"
}

// MARK: - 内側

struct LoadedFont {
    let font: CTFont
    let name: String
    let version: String?
    let characters: Set<UInt32>

    init?(data: Data, size: CGFloat) {
        guard let provider = CGDataProvider(data: data as CFData), let cg = CGFont(provider) else { return nil }
        let font = CTFontCreateWithGraphicsFont(cg, size, nil, nil)
        self.font = font
        self.name = (CTFontCopyName(font, kCTFontFullNameKey) as String?) ?? (cg.postScriptName as String? ?? "?")
        self.version = CTFontCopyName(font, kCTFontVersionNameKey) as String?
        // 持っている文字。面 0〜16 を総当たりしても数 ms。
        let set = CTFontCopyCharacterSet(font) as CharacterSet
        var chars = Set<UInt32>()
        for c in UInt32(0x20)...UInt32(0x10FFFF) {
            if c == 0xD800 { continue }
            if (0xD800...0xDFFF).contains(c) { continue }
            if let s = UnicodeScalar(c), set.contains(s) { chars.insert(c) }
        }
        self.characters = chars
    }

    /// 文字 → 字形。無ければ 0（描くと何も出ない）。
    func glyph(for c: UInt32) -> CGGlyph {
        let utf16 = Array(String(UnicodeScalar(c)!).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
        return glyphs[0]
    }
}

/// 1 文字ぶんの枠。グレー 1 byte/px、白地に黒。
///
/// 画素はこの型が持つ生のメモリに描き、返すときに写す（配列を CGContext に貸すと、
/// 次に描いたとき前に返した配列まで書き換わる）。
final class GlyphRenderer {
    let cell: Int
    private let pixels: UnsafeMutablePointer<UInt8>
    private let ctx: CGContext

    init(cell: Int) {
        self.cell = cell
        pixels = .allocate(capacity: cell * cell)
        ctx = CGContext(data: pixels, width: cell, height: cell, bitsPerComponent: 8,
                        bytesPerRow: cell, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    }
    deinit { pixels.deallocate() }

    /// 描いて画素列を返す。枠からはみ出す字形は切れるが、両側とも同じに切れる。
    func render(_ c: UInt32, with font: LoadedFont) -> [UInt8] {
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: cell, height: cell))
        ctx.setFillColor(gray: 0, alpha: 1)
        var g = font.glyph(for: c)
        var p = CGPoint(x: CGFloat(cell) * 0.15, y: CGFloat(cell) * 0.25)
        CTFontDrawGlyphs(font.font, &g, &p, 1, ctx)
        return Array(UnsafeBufferPointer(start: pixels, count: cell * cell))
    }
}
#endif
