import CoreGraphics
import Foundation
import ImageIO

/// Reads a GIF back through ImageIO so tests can assert on what actually got
/// written to disk, not just on what `performGIFExport` intended to write.
enum GIFDecoding {

    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 255, green: 255, blue: 255)

        /// Within `tolerance` per channel — GIF's palette quantization can
        /// land a decoded solid color a shade off its source value even with
        /// nothing that looks like dithering, so exact equality is the wrong
        /// bar for this check (the byte-exact golden-file test covers exact).
        func isNear(_ other: RGB, tolerance: Double = 2) -> Bool {
            abs(red - other.red) <= tolerance &&
            abs(green - other.green) <= tolerance &&
            abs(blue - other.blue) <= tolerance
        }
    }

    struct Frame {
        let width: Int
        let height: Int
        /// Mean of each channel across every pixel — a solid-color frame
        /// collapses to that color exactly; anything else is at least a
        /// coarse fingerprint of what was rendered.
        let averageColor: RGB
    }

    enum DecodingError: Error {
        case cannotOpenSource
        case cannotDecodeFrame(index: Int)
        case cannotAllocateBitmapContext
    }

    static func frames(of url: URL) throws -> [Frame] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DecodingError.cannotOpenSource
        }
        return try (0..<CGImageSourceGetCount(source)).map { index in
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw DecodingError.cannotDecodeFrame(index: index)
            }
            return try Frame(image: image)
        }
    }
}

private extension GIFDecoding.Frame {
    init(image: CGImage) throws {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw GIFDecoding.DecodingError.cannotAllocateBitmapContext
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sums = (red: 0.0, green: 0.0, blue: 0.0)
        let pixelCount = width * height
        for p in stride(from: 0, to: pixels.count, by: 4) {
            sums.red += Double(pixels[p])
            sums.green += Double(pixels[p + 1])
            sums.blue += Double(pixels[p + 2])
        }
        self.width = width
        self.height = height
        self.averageColor = GIFDecoding.RGB(
            red: sums.red / Double(pixelCount),
            green: sums.green / Double(pixelCount),
            blue: sums.blue / Double(pixelCount)
        )
    }
}
