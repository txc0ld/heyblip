import ImageIO
import UIKit

enum ImageDownsampling {
    /// Decode and downsample image data without loading the full bitmap into memory.
    ///
    /// Uses ImageIO's thumbnail pipeline so only the final, scaled pixels are
    /// allocated. A 48 MP HEIC that would produce ~150 MB at full resolution
    /// produces ~16 MB at maxPixelSize 2048 — safe for the crop-avatar view.
    ///
    /// - Parameters:
    ///   - data: Raw image bytes (HEIC, JPEG, PNG, etc.).
    ///   - maxPixelSize: Longest edge of the output image in pixels. Default 2048
    ///     gives sharp headroom for the 256×256 avatar upload target.
    /// - Returns: A downsampled `UIImage`, or `nil` if decoding fails.
    static func downsampledImage(from data: Data, maxPixelSize: CGFloat = 2048) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
