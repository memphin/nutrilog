import Foundation
import SwiftUI
import UIKit
import Vision

enum MealPhoto {
    /// Longest side sent or analysed: larger photos add upload time, not accuracy.
    static let maxSide: CGFloat = 1568

    /// A JPEG of `image`, scaled down to ``maxSide``.
    static func jpeg(from image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: 0.8)
    }
}

/// ``FoodImageLabeling`` with the Vision framework's built-in image classifier. Nothing leaves the phone.
struct VisionFoodImageLabeler: FoodImageLabeling {
    func labels(jpeg: Data) async throws -> [String] {
        try await ClassifyImageRequest().perform(on: jpeg)
            .filter { $0.confidence >= 0.2 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(12)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }
}
