import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// A photo ready to upload: its bytes, file name and type.
public struct PreparedPhoto: Equatable {
    public let data: Data
    public let filename: String
    public let contentType: String

    public init(data: Data, filename: String, contentType: String) {
        self.data = data
        self.filename = filename
        self.contentType = contentType
    }
}

/// Shrinks a photo on the phone before upload, so mobile data isn't spent on pixels the
/// server drops (it re-encodes to a JPEG of at most 2048 px). A photo the server takes as it
/// is (PNG, JPEG, GIF or WebP within ``maxDimension`` and ``maxBytes``) goes unchanged;
/// anything else (HEIC from the camera roll, a 48 MP photo, a 20 MB PNG) becomes a JPEG of
/// at most ``maxDimension`` px, turned upright, without its metadata.
public enum PhotoPreparation {
    public static let maxDimension = 4096
    public static let maxBytes = 15 * 1024 * 1024
    public static let jpegQuality = 0.85
    /// What the server accepts as-is (it checks the bytes).
    public static let uploadTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// The bytes' photo type, from their signature (not the file name): one of
    /// ``uploadTypes``, `image/heic`, or nil.
    public static func sniffType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.count >= 8, bytes[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "image/png" }
        if bytes.count >= 3, bytes[0...2] == [0xFF, 0xD8, 0xFF] { return "image/jpeg" }
        if bytes.count >= 6, let head = String(bytes: bytes[0...5], encoding: .ascii), head == "GIF87a" || head == "GIF89a" { return "image/gif" }
        if bytes.count >= 12, String(bytes: bytes[0...3], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8...11], encoding: .ascii) == "WEBP" { return "image/webp" }
        if bytes.count >= 12, String(bytes: bytes[4...7], encoding: .ascii) == "ftyp",
           let brand = String(bytes: bytes[8...11], encoding: .ascii),
           ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1", "avif"].contains(brand) {
            return brand == "avif" ? "image/avif" : "image/heic"
        }
        return nil
    }

    /// The photo to upload, or nil when the bytes aren't a photo this device can read.
    public static func prepare(data: Data, filename: String,
                               maxDimension: Int = maxDimension, maxBytes: Int = maxBytes) -> PreparedPhoto? {
        let type = sniffType(data)
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let type, uploadTypes.contains(type), max(width, height) <= maxDimension, data.count <= maxBytes {
            return PreparedPhoto(data: data, filename: filename, contentType: type)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // Upright, as the camera meant it.
            kCGImageSourceThumbnailMaxPixelSize: min(maxDimension, max(width, height, 1)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        // No metadata is copied: location and camera details stay on the phone.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PreparedPhoto(data: output as Data, filename: jpegName(filename), contentType: "image/jpeg")
        #else
        guard let type, uploadTypes.contains(type), data.count <= maxBytes else { return nil }
        return PreparedPhoto(data: data, filename: filename, contentType: type)
        #endif
    }

    static func jpegName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return "\(base.isEmpty ? "photo" : base).jpg"
    }
}
