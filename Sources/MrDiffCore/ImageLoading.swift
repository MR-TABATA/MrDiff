import Foundation

#if canImport(ImageIO)
import ImageIO
import CoreGraphics

/// 画像を読んで、**必ず同じ形式の画素列に正規化**する。
///
/// 元の形式・色空間・ビット深度をそのまま比べると、見た目が同じ PNG と JPEG が
/// 「全画素が違う」になる。8bit RGBA / sRGB へ描き直してから比べる。
///
/// **ImageIO は Apple のプラットフォームにしか無い。** CLI を Linux（CI）でも
/// 動かすなら、そこは別の復号器を足す ―― `PixelDiff.swift` は OS を知らないので、
/// 差し替えるのはこのファイルだけで済む。
public struct DecodedImage: Sendable {
    public let pixels: [UInt8]
    public let size: Size
    public let bytesPerPixel: Int
}

public enum ImageLoadError: Error, CustomStringConvertible {
    case cannotOpen(URL)
    case notAnImage(URL)
    case cannotDecode(URL)

    public var description: String {
        switch self {
        case .cannotOpen(let u):   return "cannot open \(u.path)"
        case .notAnImage(let u):   return "not an image: \(u.path)"
        case .cannotDecode(let u): return "cannot decode \(u.path)"
        }
    }
}

public func loadImage(at url: URL) throws -> DecodedImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw ImageLoadError.cannotOpen(url)
    }
    guard CGImageSourceGetCount(src) > 0,
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw ImageLoadError.notAnImage(url)
    }

    let w = cg.width, h = cg.height
    let bpp = 4
    var buf = [UInt8](repeating: 0, count: w * h * bpp)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw ImageLoadError.cannotDecode(url)
    }
    let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * bpp,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { throw ImageLoadError.cannotDecode(url) }

    return DecodedImage(pixels: buf, size: Size(width: w, height: h), bytesPerPixel: bpp)
}

/// ファイル 2 つを読んで比べる。
public func compareImages(_ a: URL, _ b: URL) throws -> ImageComparison {
    let ia = try loadImage(at: a)
    let ib = try loadImage(at: b)
    return comparePixels(
        a: ia.pixels, sizeA: ia.size,
        b: ib.pixels, sizeB: ib.size,
        bytesPerPixel: ia.bytesPerPixel
    )
}
#endif
