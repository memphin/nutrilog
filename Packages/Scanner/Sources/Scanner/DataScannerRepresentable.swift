#if os(iOS)
    import SwiftUI
    import VisionKit

    /// Thin bridge to VisionKit's `DataScannerViewController`. All decisions (symbology mapping, debounce) live in
    /// pure, unit-tested types; this only forwards detections.
    struct DataScannerRepresentable: UIViewControllerRepresentable {
        var isScanning: Bool
        var onDetect: @MainActor (ScannedBarcode) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: ScannerSymbology.recognized)],
                qualityLevel: .balanced,
                recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: true,
                isPinchToZoomEnabled: true,
                isGuidanceEnabled: true,
                isHighlightingEnabled: true,
            )
            scanner.delegate = context.coordinator
            return scanner
        }

        func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
            context.coordinator.onDetect = onDetect
            if isScanning, !scanner.isScanning {
                try? scanner.startScanning()
            } else if !isScanning, scanner.isScanning {
                scanner.stopScanning()
            }
        }

        static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator _: Coordinator) {
            scanner.stopScanning()
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(onDetect: onDetect)
        }

        @MainActor
        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            var onDetect: @MainActor (ScannedBarcode) -> Void

            init(onDetect: @escaping @MainActor (ScannedBarcode) -> Void) {
                self.onDetect = onDetect
            }

            /// `didAdd` fires as soon as a code is first recognized, which is the lowest-latency hook (FR-10, < 300 ms).
            func dataScanner(
                _: DataScannerViewController,
                didAdd addedItems: [RecognizedItem],
                allItems _: [RecognizedItem],
            ) {
                for item in addedItems {
                    guard case let .barcode(barcode) = item, let payload = barcode.payloadStringValue else { continue }
                    onDetect(ScannerSymbology.barcode(symbology: barcode.observation.symbology, payload: payload))
                }
            }
        }
    }
#endif
