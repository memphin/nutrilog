import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reference photos of nutrition labels (FR-13), one JPEG per food at `<directory>/<foodID>.jpg`.
///
/// Stored only on this device, in Application Support/LabelPhotos: not in the database, so they are not part of the
/// JSON export or sync. Deleting the food does not delete the photo (soft-deleted foods can come back).
struct LabelPhotoStore: Sendable {
    let directory: URL

    /// Application Support/LabelPhotos.
    static var live: LabelPhotoStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true,
        )) ?? FileManager.default.temporaryDirectory
        return LabelPhotoStore(directory: base.appendingPathComponent("LabelPhotos", isDirectory: true))
    }

    /// A fresh folder in the temporary directory, for tests and previews.
    static func temporary() -> LabelPhotoStore {
        LabelPhotoStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("LabelPhotos-\(UUID().uuidString)", isDirectory: true))
    }

    /// Longest side of a stored photo, in pixels: enough to read a label, small enough to keep.
    static let maxPixelSize: CGFloat = 1600

    func url(foodID: String) -> URL {
        directory.appendingPathComponent("\(foodID).jpg")
    }

    func hasPhoto(foodID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(foodID: foodID).path)
    }

    /// Writes JPEG `data` for the food, replacing any earlier photo.
    func save(_ data: Data, foodID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(foodID: foodID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load(foodID: String) -> Data? {
        try? Data(contentsOf: url(foodID: foodID))
    }

    func delete(foodID: String) throws {
        guard hasPhoto(foodID: foodID) else { return }
        try FileManager.default.removeItem(at: url(foodID: foodID))
    }

    /// Image `data` (any format ImageIO reads) downsampled so its longest side is at most `maxPixelSize`, with the
    /// EXIF orientation applied, re-encoded as JPEG. Never decodes the full-size image; safe off the main actor.
    /// Returns nil when `data` isn't a readable image.
    nonisolated static func downsampledJPEG(_ data: Data, maxPixelSize: Int = Int(maxPixelSize)) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
