import CoreGraphics
import Foundation
import TreeMapKit

extension PixelBuffer {
    /// Wraps the RGBA bytes in a CGImage (alpha is ignored, the buffer is always opaque).
    var cgImage: CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)
    }
}
