#if os(iOS)
    import AVFoundation
    import SwiftUI
    import VisionKit

    /// Live barcode scanner (FR-10) with torch toggle, haptic on detection, a 2 s same-code debounce, camera-permission
    /// handling and a manual-entry fallback (FR-14). Calls `onScan` for every accepted code; scanning continues, so the
    /// caller decides when to dismiss. Pass `isPaused` while something covers the camera (any sheet, a lookup in
    /// progress): the camera, haptics and torch stop until it is false again. When scanning resumes, the code handled
    /// last is ignored for 3 s or until it leaves the view (`ScanDebouncer.resume(at:)`), so a product still in front
    /// of the camera doesn't reopen. A typed code is delivered once the manual-entry sheet has finished dismissing.
    public struct BarcodeScannerView: View {
        private let isPaused: Bool
        private let onScan: @MainActor (ScannedBarcode) -> Void

        @State private var availability: ScannerAvailability?
        @State private var debouncer = ScanDebouncer()
        @State private var detections = 0
        @State private var isTorchOn = false
        @State private var isShowingManualEntry = false
        /// A typed code waiting for the manual-entry sheet to finish dismissing.
        @State private var manualEntry = ManualEntryHandoff()
        @Environment(\.scenePhase) private var scenePhase

        public init(isPaused: Bool = false, onScan: @escaping @MainActor (ScannedBarcode) -> Void) {
            self.isPaused = isPaused
            self.onScan = onScan
        }

        /// The camera runs only while the scanner is shown and not paused, the manual-entry sheet is closed (and its
        /// typed code delivered) and the app is active.
        private var isScanning: Bool {
            ScannerActivity.isScanning(
                availability: availability,
                isPaused: isPaused,
                isShowingManualEntry: isShowingManualEntry || manualEntry.isPending,
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
                // Whenever scanning stops, the torch goes off so the button never shows a stale state. From then until
                // 3 s after it resumes, the code handled last (likely still in view) is suppressed.
                .onChange(of: isScanning) { _, scanning in
                    if scanning {
                        debouncer.resume()
                    } else {
                        debouncer.pause()
                        turnTorchOff()
                    }
                }
                .onDisappear(perform: turnTorchOff)
                // The typed code goes out only after the sheet is gone, so the caller can present its own sheet.
                .sheet(isPresented: $isShowingManualEntry, onDismiss: deliverManualEntry) {
                    NavigationStack {
                        ManualBarcodeEntryView { barcode in
                            manualEntry.submit(barcode)
                            isShowingManualEntry = false
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(String(localized: "Cancel", bundle: .module)) { isShowingManualEntry = false }
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
                onRemove: { payload in debouncer.codeLeftView(payload) },
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
                                isTorchOn
                                    ? String(localized: "Turn Torch Off", bundle: .module)
                                    : String(localized: "Turn Torch On", bundle: .module),
                                systemImage: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                            )
                        }
                        .accessibilityIdentifier("scannerTorch")
                    }
                    Button(action: showManualEntry) {
                        Label(String(localized: "Enter Manually", bundle: .module), systemImage: "keyboard")
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
            manualEntry = ManualEntryHandoff() // nothing from an earlier sheet can still be waiting
            isShowingManualEntry = true
        }

        private func deliverManualEntry() {
            guard let barcode = manualEntry.sheetDidDismiss() else { return }
            debouncer.noteHandled(barcode.payload)
            onScan(barcode)
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
                    Button(String(localized: "Open Settings", bundle: .module)) { openURL(url) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("scannerOpenSettings")
                }
                Button(String(localized: "Enter Barcode Manually", bundle: .module), action: onManualEntry)
                    .accessibilityIdentifier("scannerManualEntryFallback")
            }
        }

        private var title: String {
            switch reason {
            case .denied: String(localized: "Camera Access Off", bundle: .module)
            case .restricted: String(localized: "Camera Restricted", bundle: .module)
            case .unsupported: String(localized: "Scanning Not Available", bundle: .module)
            case .unavailable: String(localized: "Camera Unavailable", bundle: .module)
            }
        }

        private var message: String {
            switch reason {
            case .denied:
                String(
                    localized: """
                    Vitalion needs the camera to scan product barcodes. Turn on Camera for Vitalion in Settings, \
                    or type the barcode instead.
                    """,
                    bundle: .module,
                )
            case .restricted:
                String(
                    localized: "Camera access is restricted on this device, e.g. by Screen Time. You can type the barcode instead.",
                    bundle: .module,
                )
            case .unsupported:
                String(
                    localized: "This device can't scan barcodes with the camera. You can type the barcode instead.",
                    bundle: .module,
                )
            case .unavailable:
                String(
                    localized: """
                    The camera can't be used right now, e.g. because another app is using it. \
                    You can type the barcode instead.
                    """,
                    bundle: .module,
                )
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
