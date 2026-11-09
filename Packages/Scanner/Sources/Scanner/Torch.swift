#if os(iOS)
    import AVFoundation

    /// Torch control. `DataScannerViewController` has no torch API, so this toggles the back camera's torch directly;
    /// the torch is shared hardware, so it lights while the scanner's capture session is running.
    @MainActor
    enum Torch {
        private static var device: AVCaptureDevice? {
            AVCaptureDevice.default(for: .video).flatMap { $0.hasTorch ? $0 : nil }
        }

        static var isAvailable: Bool {
            device != nil
        }

        /// Whether the torch is actually lit right now.
        static var isOn: Bool {
            device?.torchMode == .on
        }

        /// Switches the torch and returns its actual state afterwards (unchanged when switching failed).
        @discardableResult
        static func set(_ on: Bool) -> Bool {
            guard let device else { return false }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if on {
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    device.torchMode = .off
                }
            } catch {
                // Fall through and report the device's real state.
            }
            return device.torchMode == .on
        }
    }
#endif
