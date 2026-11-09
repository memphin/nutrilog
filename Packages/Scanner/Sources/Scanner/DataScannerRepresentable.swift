#if os(iOS)
    import OSLog
    import SwiftUI
    import VisionKit

    /// Thin bridge to VisionKit's `DataScannerViewController`. All decisions (symbology mapping, debounce) live in
    /// pure, unit-tested types; this only forwards detections and start failures.
    struct DataScannerRepresentable: UIViewControllerRepresentable {
        var isScanning: Bool
        var onDetect: @MainActor (ScannedBarcode) -> Void
        /// Called when `startScanning()` throws (e.g. the camera is in use or became unavailable).
        var onStartFailure: @MainActor (Error) -> Void

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
                do {
                    try scanner.startScanning()
                } catch {
                    // Report after this view update so the caller can change state safely.
                    let onStartFailure = onStartFailure
                    Task { @MainActor in onStartFailure(error) }
                }
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
                    let symbology = barcode.observation.symbology
                    #if DEBUG
                        // Confirms on device which payload formats Vision delivers (e.g. UPC-A as 12 or 13 digits,
                        // UPC-E as 6, 7 or 8 digits).
                        Self.logger.debug(
                            "Detected \(symbology.rawValue, privacy: .public) payload \(payload, privacy: .public)",
                        )
                    #endif
                    onDetect(ScannerSymbology.barcode(symbology: symbology, payload: payload))
                }
            }

            #if DEBUG
                private static let logger = Logger(subsystem: "Scanner", category: "DataScanner")
            #endif
        }
    }
#endif
