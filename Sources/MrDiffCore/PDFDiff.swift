import Foundation

#if canImport(PDFKit)
import PDFKit
import CoreGraphics

/// PDF の比較。**ページごとに描いて、画素で比べる。**
///
/// PDF は Adobe 系の道具が最後に吐く形なので、バイナリ比較に落として「どこかのバイトが違う」
/// では役に立たない ―― 1 文字直しただけで圧縮ストリームが組み直され、以降のオフセットが
/// 全部ずれる。ページを絵にしてから `comparePixels` に掛ければ、校正で知りたい
/// 「どのページの、どのあたりか」に答えられる。
///
/// **場所はページの単位（mm）で言う。** 画素の座標は描いた解像度に縛られるが、
/// 「上から 31 mm」は紙の上の場所なので、解像度を変えても同じことを指す。
///
/// 描くのは PDFKit（Apple のプラットフォームにしか無い。ImageIO と同じ縛り）。
/// 判定は `PixelDiff.swift` / `PixelRegions.swift` のものをそのまま使う ―― PDF 用に
/// 別の規則を持たない。

/// PDF の 1 ページの大きさ（mm）。
public struct PDFPageSize: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// 違いの塊の、紙の上での位置と大きさ（mm、左上が原点）。
public struct PDFRegion: Equatable, Sendable {
    public let top: Double
    public let left: Double
    public let width: Double
    public let height: Double
    /// 塊に含まれる、違う画素の数。
    public let count: Int
    public init(top: Double, left: Double, width: Double, height: Double, count: Int) {
        self.top = top; self.left = left; self.width = width; self.height = height; self.count = count
    }
}

/// 1 ページの違い。数は画素（描いた解像度で）、場所は mm。
public struct PDFPageDiff: Equatable, Sendable {
    public let pixels: PixelDiff
    /// 左上から読む順。
    public let regions: [PDFRegion]
    public init(pixels: PixelDiff, regions: [PDFRegion]) { self.pixels = pixels; self.regions = regions }
}

/// 1 ページの答え。画像の `ImageComparison` と同じ 3 つ。
public enum PDFPageComparison: Equatable, Sendable {
    case identical
    /// 紙の大きさが違う。**それ以上は比べない**（画像と同じ理由）。
    case sizeMismatch(PDFPageSize, PDFPageSize)
    case differ(PDFPageDiff)
}

/// 全体の答え。ページは番号で突き合わせる（1 ページ目と 1 ページ目）。
/// **ページ数が違えば、余った側は比べない** ―― 「増えた／減った」として数だけ言う。
public struct PDFComparison: Equatable, Sendable {
    public let pagesA: Int
    public let pagesB: Int
    /// 両方にあるページ（`min(pagesA, pagesB)` 枚）の答え。添字 0 が 1 ページ目。
    public let pages: [PDFPageComparison]
    /// 描いた解像度。塊の数は `near`（`differenceRegions`）とこれに依るので、出力に書く。
    public let dpi: Int

    public init(pagesA: Int, pagesB: Int, pages: [PDFPageComparison], dpi: Int) {
        self.pagesA = pagesA; self.pagesB = pagesB; self.pages = pages; self.dpi = dpi
    }

    /// ページ数も中身も同じ。
    public var isIdentical: Bool {
        pagesA == pagesB && pages.allSatisfy { $0 == .identical }
    }
    /// 違ったページの番号（1 始まり）。大きさが違うページも数える。
    public var differingPages: [Int] {
        pages.enumerated().compactMap { $0.element == .identical ? nil : $0.offset + 1 }
    }
}

public enum PDFLoadError: Error, CustomStringConvertible {
    case notAPDF
    case cannotRender(page: Int)

    public var description: String {
        switch self {
        case .notAPDF:                 return t("error.not_a_pdf")
        case .cannotRender(let page):  return t("error.pdf_render", page)
        }
    }
}

/// 中身が PDF か。**拡張子は見ない**（画像と同じ線）。
///
/// ImageIO は PDF も「画像」として読んでしまう（1 ページ目だけ）ので、`looksLikeImage`
/// より**先に**これを聞かないと、複数ページの PDF が 1 枚の絵として比べられる。
/// 頭の `%PDF-` は 1024 バイト以内にあればよい（仕様がそう言っている）。開けることまで確かめる。
public func looksLikePDF(_ data: Data) -> Bool {
    let head = data.prefix(1024)
    guard head.range(of: Data("%PDF-".utf8)) != nil else { return false }
    guard let doc = PDFDocument(data: data) else { return false }
    return doc.pageCount > 0
}

/// 1 pt = 1/72 inch。紙の単位は mm で言う。
private let mmPerPoint = 25.4 / 72.0

/// ページを白地の RGBA に描く。`dpi` は 72 が等倍（1 pt = 1 px）。
/// GUI が見せる用に高い dpi で描き直すのにも使う（判定と同じ描き手で）。
///
/// 回転（`/Rotate`）は PDFKit が面倒を見るので、`bounds(for: .cropBox)` の向きのまま描く。
/// 透明は白で潰す ―― 紙に刷れば白なので、`ignoreAlpha` の出番が無い。
public func renderPDFPage(_ page: PDFPage, dpi: Int) throws -> DecodedImage {
    let box = page.bounds(for: .cropBox)
    let scale = Double(dpi) / 72.0
    let w = max(1, Int((box.width * scale).rounded(.up)))
    let h = max(1, Int((box.height * scale).rounded(.up)))
    let bpp = 4
    var buf = [UInt8](repeating: 0, count: w * h * bpp)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw PDFLoadError.cannotRender(page: 0) }
    let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * bpp, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        return true
    }
    guard ok else { throw PDFLoadError.cannotRender(page: 0) }
    return DecodedImage(pixels: buf, size: Size(width: w, height: h), bytesPerPixel: bpp)
}

/// PDF 2 つを比べる。
///
/// - Parameters:
///   - dpi: 描く解像度。既定 72（1 pt = 1 px。A4 で 595×842、文字の直しは十分に出る）。
///   - tolerance: 画像と同じ、1 チャンネルあたりの許容差。同じ描き手で描くので普段は 0 でよい。
public func comparePDFs(_ a: Data, _ b: Data, dpi: Int = 72, tolerance: Int = 0) throws -> PDFComparison {
    guard let da = PDFDocument(data: a), let db = PDFDocument(data: b),
          da.pageCount > 0, db.pageCount > 0 else { throw PDFLoadError.notAPDF }

    let common = min(da.pageCount, db.pageCount)
    var pages: [PDFPageComparison] = []
    pages.reserveCapacity(common)
    for i in 0..<common {
        guard let pa = da.page(at: i), let pb = db.page(at: i) else { throw PDFLoadError.cannotRender(page: i + 1) }
        let ia: DecodedImage, ib: DecodedImage
        do { ia = try renderPDFPage(pa, dpi: dpi); ib = try renderPDFPage(pb, dpi: dpi) }
        catch { throw PDFLoadError.cannotRender(page: i + 1) }

        switch comparePixels(a: ia.pixels, sizeA: ia.size, b: ib.pixels, sizeB: ib.size,
                             bytesPerPixel: ia.bytesPerPixel, tolerance: tolerance) {
        case .identical:
            pages.append(.identical)
        case .sizeMismatch:
            pages.append(.sizeMismatch(pageSize(pa), pageSize(pb)))
        case .differ(let d):
            // 塊は判定側がまとめる（GUI と同じ材料）。画素 → mm はここで。
            let mask = differingPixels(a: ia.pixels, sizeA: ia.size, b: ib.pixels, sizeB: ib.size,
                                       bytesPerPixel: ia.bytesPerPixel, tolerance: tolerance) ?? []
            let mmPerPixel = mmPerPoint * 72.0 / Double(dpi)
            let regions = differenceRegions(mask: mask, width: ia.size.width, height: ia.size.height).map {
                PDFRegion(top: Double($0.y) * mmPerPixel, left: Double($0.x) * mmPerPixel,
                          width: Double($0.width) * mmPerPixel, height: Double($0.height) * mmPerPixel,
                          count: $0.count)
            }
            pages.append(.differ(PDFPageDiff(pixels: d, regions: regions)))
        }
    }
    return PDFComparison(pagesA: da.pageCount, pagesB: db.pageCount, pages: pages, dpi: dpi)
}

private func pageSize(_ page: PDFPage) -> PDFPageSize {
    let box = page.bounds(for: .cropBox)
    return PDFPageSize(width: box.width * mmPerPoint, height: box.height * mmPerPoint)
}
#endif
