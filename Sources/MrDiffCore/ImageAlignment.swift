import Foundation

/// B を A の上に置くときの、信頼できる平行移動量を見つける。
///
/// 拡大縮小や回転はせず、±128 px の範囲だけを探す。位置合わせで差分を隠さないよう、
/// 呼び出し側は返されたずらし量を表示する。画面全体が似ていない場合や、ずらしても
/// 十分に一致度が上がらない場合は nil を返す。
public func estimateImageOffset(
    a imageA: [UInt8], sizeA: Size,
    b imageB: [UInt8], sizeB: Size,
    bytesPerPixel: Int
) -> Point? {
    let images = AlignmentImagePair(
        imageA: AlignmentImageBuffer(pixels: imageA, size: sizeA),
        imageB: AlignmentImageBuffer(pixels: imageB, size: sizeB),
        bytesPerPixel: bytesPerPixel
    )
    return ImageOffsetEstimator.estimate(images)
}

private struct AlignmentImageBuffer {
    let pixels: [UInt8]
    let size: Size
}

private struct AlignmentImagePair {
    let imageA: AlignmentImageBuffer
    let imageB: AlignmentImageBuffer
    let bytesPerPixel: Int
}

private struct AlignmentCandidate {
    let point: Point
    let score: Double
}

private enum ImageOffsetEstimator {
    private static let maxOffset = 128
    private static let downsampleScale = 4
    private static let coarseStep = 2
    private static let maxSamplesPerAlignmentScore = 4_096

    static func estimate(_ images: AlignmentImagePair) -> Point? {
        guard images.bytesPerPixel >= 3,
              isValidImageBuffer(images.imageA, bytesPerPixel: images.bytesPerPixel),
              isValidImageBuffer(images.imageB, bytesPerPixel: images.bytesPerPixel) else { return nil }

        let coarseImages = downsample(images)
        let coarseMaxOffset = maxOffset / downsampleScale
        let coarse = coarseCandidates(coarseImages, maxOffset: coarseMaxOffset, minimumSampleStep: 4)
        guard !coarse.isEmpty else { return nil }

        guard let best = bestCandidate(
            images, coarse: coarse, minimumSampleStep: 8
        ), isReliable(best, images: images) else { return nil }
        return best.point
    }

    private static func downsample(_ images: AlignmentImagePair) -> AlignmentImagePair {
        let imageA = downsample(images.imageA, bytesPerPixel: images.bytesPerPixel)
        let imageB = downsample(images.imageB, bytesPerPixel: images.bytesPerPixel)
        return AlignmentImagePair(imageA: imageA, imageB: imageB, bytesPerPixel: 1)
    }

    private static func coarseCandidates(
        _ images: AlignmentImagePair, maxOffset: Int, minimumSampleStep: Int
    ) -> [AlignmentCandidate] {
        let offsets = Array(stride(from: -maxOffset, through: maxOffset, by: coarseStep))
        var candidates: [AlignmentCandidate] = []
        for verticalOffset in offsets {
            for horizontalOffset in offsets {
                let point = Point(x: horizontalOffset, y: verticalOffset)
                if let score = alignmentScore(images, offset: point, minimumSampleStep: minimumSampleStep) {
                    candidates.append(AlignmentCandidate(point: point, score: score))
                }
            }
        }
        return candidates.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            return offsetDistance($0.point) < offsetDistance($1.point)
        }
    }

    private static func bestCandidate(
        _ images: AlignmentImagePair, coarse: [AlignmentCandidate], minimumSampleStep: Int
    ) -> AlignmentCandidate? {
        let seeds = Array(coarse.prefix(4)) + [
            AlignmentCandidate(point: Point(x: 0, y: 0), score: 0)
        ]
        let fineRadius = coarseStep * downsampleScale / 2
        var best: AlignmentCandidate?
        for seed in seeds {
            let seedX = seed.point.x * downsampleScale
            let seedY = seed.point.y * downsampleScale
            let verticalRange = max(-maxOffset, seedY - fineRadius)...min(maxOffset, seedY + fineRadius)
            let horizontalRange = max(-maxOffset, seedX - fineRadius)...min(maxOffset, seedX + fineRadius)
            for verticalOffset in verticalRange {
                for horizontalOffset in horizontalRange {
                    let point = Point(x: horizontalOffset, y: verticalOffset)
                    guard let score = alignmentScore(
                        images, offset: point, minimumSampleStep: minimumSampleStep
                    ) else {
                        continue
                    }
                    let candidate = AlignmentCandidate(point: point, score: score)
                    if isBetter(candidate, than: best) { best = candidate }
                }
            }
        }
        return best
    }

    private static func isBetter(_ candidate: AlignmentCandidate, than current: AlignmentCandidate?) -> Bool {
        guard let current else { return true }
        if candidate.score != current.score { return candidate.score < current.score }
        return offsetDistance(candidate.point) < offsetDistance(current.point)
    }

    private static func isReliable(_ best: AlignmentCandidate, images: AlignmentImagePair) -> Bool {
        let zeroOffset = Point(x: 0, y: 0)
        guard best.point != zeroOffset,
              let originalScore = alignmentScore(images, offset: zeroOffset, minimumSampleStep: 4),
              let alignedScore = alignmentScore(images, offset: best.point, minimumSampleStep: 4) else {
            return false
        }
        return alignedScore <= 0.20 && originalScore - alignedScore >= 0.015
    }

    private static func alignmentScore(
        _ images: AlignmentImagePair, offset: Point, minimumSampleStep: Int
    ) -> Double? {
        let sizeA = images.imageA.size
        let sizeB = images.imageB.size
        let overlap = overlapRect(sizeA: sizeA, sizeB: sizeB, offset: offset)
        guard overlap.x1 > overlap.x0, overlap.y1 > overlap.y0 else { return nil }

        let overlapArea = (overlap.x1 - overlap.x0) * (overlap.y1 - overlap.y0)
        let smallerArea = min(sizeA.width * sizeA.height, sizeB.width * sizeB.height)
        guard Double(overlapArea) / Double(smallerArea) >= 0.6 else { return nil }
        let sampleStep = adaptiveSampleStep(
            width: overlap.x1 - overlap.x0,
            height: overlap.y1 - overlap.y0,
            minimumStep: minimumSampleStep
        )

        var totalDifference = 0
        var samples = 0
        for rowIndex in stride(from: overlap.y0, to: overlap.y1, by: sampleStep) {
            let rowA = rowIndex * sizeA.width * images.bytesPerPixel
            let rowB = (rowIndex - offset.y) * sizeB.width * images.bytesPerPixel
            for columnIndex in stride(from: overlap.x0, to: overlap.x1, by: sampleStep) {
                let indexA = rowA + columnIndex * images.bytesPerPixel
                let indexB = rowB + (columnIndex - offset.x) * images.bytesPerPixel
                totalDifference += pixelDifference(images, indexA: indexA, indexB: indexB)
                samples += 1
            }
        }
        guard samples > 0 else { return nil }
        return Double(totalDifference) / Double(samples * 255)
    }

    private static func adaptiveSampleStep(width: Int, height: Int, minimumStep: Int) -> Int {
        var step = max(minimumStep, Int(ceil(sqrt(
            Double(width) * Double(height) / Double(maxSamplesPerAlignmentScore)
        ))))
        while sampleCount(width, step: step) > maxSamplesPerAlignmentScore / sampleCount(height, step: step) {
            step += 1
        }
        return step
    }

    private static func sampleCount(_ length: Int, step: Int) -> Int {
        (length + step - 1) / step
    }

    private static func pixelDifference(
        _ images: AlignmentImagePair, indexA: Int, indexB: Int
    ) -> Int {
        if images.bytesPerPixel == 1 {
            return abs(Int(images.imageA.pixels[indexA]) - Int(images.imageB.pixels[indexB]))
        }
        return abs(luminance(images.imageA.pixels, at: indexA)
                   - luminance(images.imageB.pixels, at: indexB))
    }

    private static func isValidImageBuffer(_ image: AlignmentImageBuffer, bytesPerPixel: Int) -> Bool {
        guard image.size.width > 0, image.size.height > 0, bytesPerPixel > 0 else { return false }
        let (pixelCount, pixelOverflow) = image.size.width.multipliedReportingOverflow(by: image.size.height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: bytesPerPixel)
        return !pixelOverflow && !byteOverflow && image.pixels.count >= byteCount
    }

    private static func downsample(
        _ image: AlignmentImageBuffer, bytesPerPixel: Int
    ) -> AlignmentImageBuffer {
        let width = 1 + (image.size.width - 1) / downsampleScale
        let height = 1 + (image.size.height - 1) / downsampleScale
        var output = [UInt8](repeating: 0, count: width * height)
        for rowIndex in 0..<height {
            for columnIndex in 0..<width {
                let originX = columnIndex * downsampleScale
                let originY = rowIndex * downsampleScale
                let endX = min(image.size.width, originX + downsampleScale)
                let endY = min(image.size.height, originY + downsampleScale)
                var sum = 0
                var count = 0
                for sourceY in originY..<endY {
                    let row = sourceY * image.size.width * bytesPerPixel
                    for sourceX in originX..<endX {
                        sum += luminance(image.pixels, at: row + sourceX * bytesPerPixel)
                        count += 1
                    }
                }
                output[rowIndex * width + columnIndex] = UInt8(sum / count)
            }
        }
        return AlignmentImageBuffer(pixels: output, size: Size(width: width, height: height))
    }

    private static func luminance(_ pixels: [UInt8], at index: Int) -> Int {
        (Int(pixels[index]) * 54 + Int(pixels[index + 1]) * 183 + Int(pixels[index + 2]) * 19) / 256
    }

    private static func offsetDistance(_ point: Point) -> Int {
        abs(point.x) + abs(point.y)
    }
}
