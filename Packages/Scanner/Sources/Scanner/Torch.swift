#if os(iOS)
    import AVFoundation

    /// Torch control. `DataScannerViewController` has no torch API, so this toggles the back camera's torch directly;
    /// the torch is shared hardware, so it lights while the scanner's capture session is running.
    @MainActor
    enum Torch {
        static var isAvailable: Bool {
            AVCaptureDevice.default(for: .video)?.hasTorch ?? false
        }

        /// Returns the torch state actually applied (`false` when it couldn't be switched on).
        @discardableResult
        static func set(_ on: Bool) -> Bool {
            guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return false }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if on {
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    device.torchMode = .off
                }
                return on
            } catch {
                return false
            }
        }
    }
#endif
