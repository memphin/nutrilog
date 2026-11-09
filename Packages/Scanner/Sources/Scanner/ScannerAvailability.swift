import AVFoundation

/// What the scanner screen shows, decided from camera permission and device support.
public enum ScannerAvailability: Equatable, Sendable {
    /// Permission not asked yet: request it, then re-evaluate.
    case needsPermission
    case ready
    /// Denied by the user: explain and link to Settings.
    case denied
    /// Blocked by Screen Time or device management: explain; Settings can't change it.
    case restricted
    /// No camera or no VisionKit support (older device, simulator): manual entry only.
    case unsupported
    /// Supported and permitted, but the camera can't be used right now (`DataScannerViewController.isAvailable`
    /// is false, or starting the scanner failed): manual entry only.
    case unavailable

    /// - Parameters:
    ///   - isSupported: `DataScannerViewController.isSupported`.
    ///   - isAvailable: `DataScannerViewController.isAvailable`. Only consulted once permission is granted, since
    ///     it is also false while permission is undetermined or denied.
    public init(authorization: AVAuthorizationStatus, isSupported: Bool, isAvailable: Bool) {
        guard isSupported else {
            self = .unsupported
            return
        }
        switch authorization {
        case .notDetermined: self = .needsPermission
        case .authorized: self = isAvailable ? .ready : .unavailable
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }
}
