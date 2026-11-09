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

    public init(authorization: AVAuthorizationStatus, isSupported: Bool) {
        guard isSupported else {
            self = .unsupported
            return
        }
        switch authorization {
        case .notDetermined: self = .needsPermission
        case .authorized: self = .ready
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }
}
