#if os(iOS)
    import AVFoundation
    import SwiftUI
    import VisionKit

    /// Live barcode scanner (FR-10) with torch toggle, haptic on detection, a 2 s same-code debounce, camera-permission
    /// handling and a manual-entry fallback (FR-14). Calls `onScan` for every accepted code; scanning continues, so the
    /// caller decides when to dismiss. Pass `isPaused` while something covers the camera (a result sheet, a lookup in
    /// progress): the camera, haptics and torch stop until it is false again.
    public struct BarcodeScannerView: View {
        private let isPaused: Bool
        private let onScan: @MainActor (ScannedBarcode) -> Void

        @State private var availability: ScannerAvailability?
        @State private var debouncer = ScanDebouncer()
        @State private var detections = 0
        @State private var isTorchOn = false
        @State private var isShowingManualEntry = false
        @Environment(\.scenePhase) private var scenePhase

        public init(isPaused: Bool = false, onScan: @escaping @MainActor (ScannedBarcode) -> Void) {
            self.isPaused = isPaused
            self.onScan = onScan
        }

        /// The camera runs only while the scanner is shown and not paused, the manual-entry sheet is closed and the
        /// app is active.
        private var isScanning: Bool {
            ScannerActivity.isScanning(
                availability: availability,
                isPaused: isPaused,
                isShowingManualEntry: isShowingManualEntry,
                isAppActive: scenePhase == .active,
            )
        }

        public var body: some View {
            content
                .sensoryFeedback(.success, trigger: detections)
                .task { await refreshAvailability(requestIfNeeded: true) }
                // Re-check when coming back from Settings (or after the camera was busy).
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await refreshAvailability(requestIfNeeded: false) }
                    }
                }
                // Whenever scanning stops, the torch goes off so the button never shows a stale state.
                .onChange(of: isScanning) { _, scanning in
                    if !scanning {
                        turnTorchOff()
                    }
                }
                .onDisappear(perform: turnTorchOff)
                .sheet(isPresented: $isShowingManualEntry) {
                    NavigationStack {
                        ManualBarcodeEntryView { barcode in
                            isShowingManualEntry = false
                            onScan(barcode)
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { isShowingManualEntry = false }
                            }
                        }
                    }
                }
        }

        @ViewBuilder private var content: some View {
            switch availability {
            case nil, .needsPermission:
                ProgressView()
            case .ready:
                scanner
            case .denied:
                CameraUnavailableView(reason: .denied, onManualEntry: showManualEntry)
            case .restricted:
                CameraUnavailableView(reason: .restricted, onManualEntry: showManualEntry)
            case .unsupported:
                CameraUnavailableView(reason: .unsupported, onManualEntry: showManualEntry)
            case .unavailable:
                CameraUnavailableView(reason: .unavailable, onManualEntry: showManualEntry)
            }
        }

        private var scanner: some View {
            DataScannerRepresentable(
                isScanning: isScanning,
                onDetect: handle,
                onStartFailure: { _ in availability = .unavailable },
            )
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                HStack(spacing: 16) {
                    if Torch.isAvailable {
                        Button {
                            isTorchOn = Torch.set(!isTorchOn)
                        } label: {
                            Label(
                                isTorchOn ? "Turn Torch Off" : "Turn Torch On",
                                systemImage: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                            )
                        }
                        .accessibilityIdentifier("scannerTorch")
                    }
                    Button(action: showManualEntry) {
                        Label("Enter Manually", systemImage: "keyboard")
                    }
                    .accessibilityIdentifier("scannerManualEntry")
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.bottom, 24)
            }
        }

        private func showManualEntry() {
            isShowingManualEntry = true
        }

        private func turnTorchOff() {
            if isTorchOn || Torch.isOn {
                isTorchOn = Torch.set(false)
            }
        }

        private func handle(_ barcode: ScannedBarcode) {
            guard isScanning, debouncer.accept(barcode.payload) else { return }
            detections += 1
            onScan(barcode)
        }

        private func refreshAvailability(requestIfNeeded: Bool) async {
            var status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined, requestIfNeeded {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = AVCaptureDevice.authorizationStatus(for: .video)
            }
            availability = ScannerAvailability(
                authorization: status,
                isSupported: DataScannerViewController.isSupported,
                isAvailable: DataScannerViewController.isAvailable,
            )
        }
    }

    /// Shown instead of the camera when it can't be used; always offers manual entry.
    struct CameraUnavailableView: View {
        enum Reason {
            case denied, restricted, unsupported, unavailable
        }

        let reason: Reason
        let onManualEntry: () -> Void
        @Environment(\.openURL) private var openURL

        var body: some View {
            ContentUnavailableView {
                Label(title, systemImage: "camera.fill")
            } description: {
                Text(message)
            } actions: {
                if reason == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("scannerOpenSettings")
                }
                Button("Enter Barcode Manually", action: onManualEntry)
                    .accessibilityIdentifier("scannerManualEntryFallback")
            }
        }

        private var title: String {
            switch reason {
            case .denied: "Camera Access Off"
            case .restricted: "Camera Restricted"
            case .unsupported: "Scanning Not Available"
            case .unavailable: "Camera Unavailable"
            }
        }

        private var message: String {
            switch reason {
            case .denied:
                "Nutrilog needs the camera to scan product barcodes. Turn on Camera for Nutrilog in Settings, "
                    + "or type the barcode instead."
            case .restricted:
                "Camera access is restricted on this device, e.g. by Screen Time. You can type the barcode instead."
            case .unsupported:
                "This device can't scan barcodes with the camera. You can type the barcode instead."
            case .unavailable:
                "The camera can't be used right now, e.g. because another app is using it. "
                    + "You can type the barcode instead."
            }
        }
    }

    #Preview("Permission denied") {
        CameraUnavailableView(reason: .denied, onManualEntry: {})
    }

    #Preview("Manual entry") {
        NavigationStack {
            ManualBarcodeEntryView { _ in }
        }
    }
#endif
