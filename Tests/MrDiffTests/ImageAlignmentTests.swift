import XCTest
@testable import MrDiffCore

final class ImageAlignmentTests: XCTestCase {
    func test_画面を移動した画像のずらしを推定する() {
        let size = Size(width: 96, height: 80)
        let bytesPerPixel = 4
        let imageA = texturedImage(size: size, bytesPerPixel: bytesPerPixel, seed: 0x12345678)

        let expected = Point(x: 24, y: -16)
        let imageB = shiftedImage(imageA, size: size, bytesPerPixel: bytesPerPixel, offset: expected)

        XCTAssertEqual(estimateImageOffset(a: imageA, sizeA: size, b: imageB, sizeB: size,
                                           bytesPerPixel: bytesPerPixel), expected)
    }

    func test_4K画像ではサンプル数を抑えて位置を推定する() {
        let size = Size(width: 3_840, height: 2_160)
        let bytesPerPixel = 4
        let imageA = texturedImage(size: size, bytesPerPixel: bytesPerPixel, seed: 0x12345678)
        let expected = Point(x: 24, y: -16)
        let imageB = shiftedImage(imageA, size: size, bytesPerPixel: bytesPerPixel, offset: expected)

        XCTAssertEqual(estimateImageOffset(a: imageA, sizeA: size, b: imageB, sizeB: size,
                                           bytesPerPixel: bytesPerPixel), expected)
    }

    func test_模様がある同一画像では位置を推定しない() {
        let size = Size(width: 96, height: 80)
        let image = texturedImage(size: size, bytesPerPixel: 4, seed: 0x12345678)

        XCTAssertNil(estimateImageOffset(a: image, sizeA: size, b: image, sizeB: size,
                                         bytesPerPixel: 4))
    }

    func test_無関係な画像同士では位置を推定しない() {
        let size = Size(width: 96, height: 80)
        let imageA = texturedImage(size: size, bytesPerPixel: 4, seed: 0x12345678)
        let imageB = texturedImage(size: size, bytesPerPixel: 4, seed: 0x87654321)

        XCTAssertNil(estimateImageOffset(a: imageA, sizeA: size, b: imageB, sizeB: size,
                                         bytesPerPixel: 4))
    }

    func test_一様画像では位置を推定しない() {
        let size = Size(width: 64, height: 64)
        let pixels = [UInt8](repeating: 128, count: size.width * size.height * 4)

        XCTAssertNil(estimateImageOffset(a: pixels, sizeA: size, b: pixels, sizeB: size,
                                         bytesPerPixel: 4))
    }

    func test_不正な画素列では位置を推定しない() {
        XCTAssertNil(estimateImageOffset(a: [0, 0, 0], sizeA: Size(width: 2, height: 2),
                                         b: [0, 0, 0], sizeB: Size(width: 2, height: 2),
                                         bytesPerPixel: 4))
    }

    private func texturedImage(size: Size, bytesPerPixel: Int, seed: UInt32) -> [UInt8] {
        var image = [UInt8](repeating: 0, count: size.width * size.height * bytesPerPixel)
        var random = seed
        for pixel in 0..<(size.width * size.height) {
            random = random &* 1_664_525 &+ 1_013_904_223
            let index = pixel * bytesPerPixel
            image[index] = UInt8(truncatingIfNeeded: random >> 16)
            image[index + 1] = UInt8(truncatingIfNeeded: random >> 8)
            image[index + 2] = UInt8(truncatingIfNeeded: random)
            image[index + 3] = 255
        }
        return image
    }

    private func shiftedImage(
        _ image: [UInt8], size: Size, bytesPerPixel: Int, offset: Point
    ) -> [UInt8] {
        var shifted = [UInt8](repeating: 0, count: image.count)
        for rowIndex in 0..<size.height {
            for columnIndex in 0..<size.width {
                let sourceX = columnIndex + offset.x
                let sourceY = rowIndex + offset.y
                guard (0..<size.width).contains(sourceX), (0..<size.height).contains(sourceY) else {
                    continue
                }
                let source = (sourceY * size.width + sourceX) * bytesPerPixel
                let destination = (rowIndex * size.width + columnIndex) * bytesPerPixel
                shifted[destination..<(destination + bytesPerPixel)] = image[source..<(source + bytesPerPixel)]
            }
        }
        return shifted
    }
}
