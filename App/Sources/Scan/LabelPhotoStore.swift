import Foundation
import UIKit

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

    /// `image` downscaled to ``maxPixelSize`` and encoded as JPEG.
    static func jpegData(from image: UIImage) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height) * image.scale
        guard longest > 0 else { return nil }
        let factor = min(1, maxPixelSize / longest)
        let target = CGSize(width: size.width * image.scale * factor, height: size.height * image.scale * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }
}
