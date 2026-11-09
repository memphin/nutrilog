/// When the camera should be scanning. Pure, so it can be tested without a camera.
public enum ScannerActivity {
    /// Scanning only when the camera is ready, the caller hasn't paused it (e.g. a result sheet covers it), the
    /// manual-entry sheet is closed and the app is active.
    public static func isScanning(
        availability: ScannerAvailability?,
        isPaused: Bool,
        isShowingManualEntry: Bool,
        isAppActive: Bool,
    ) -> Bool {
        availability == .ready && !isPaused && !isShowingManualEntry && isAppActive
    }
}
