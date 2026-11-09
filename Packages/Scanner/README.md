# Scanner

Barcode scanning (FR-10) and manual barcode entry (FR-14).

- `BarcodeScannerView(onScan:)`: VisionKit `DataScannerViewController` wrapper (iOS only). Continuous scanning of
  EAN-13, EAN-8, UPC-A, UPC-E and Code-128, torch toggle, haptic on detection, 2 s same-code debounce, camera
  permission handling (denied: explanation + link to Settings) and a manual-entry fallback.
- `ManualBarcodeEntryView(onSubmit:)`: standalone manual entry; submits only codes with a valid check digit.
- Pure, platform-independent logic (unit-tested): `ScanDebouncer`, `ScannerSymbology` (Vision → `Core.Barcode.Symbology`),
  `ManualBarcodeValidation`, `ScannerAvailability`.

Callbacks receive a `ScannedBarcode` (raw payload, Core symbology, and `candidates`: every normalized key, most likely
first). A typed 8-digit code valid both as EAN-8 and as UPC-E is reported as `.unknown` with both keys.
Code-128 has no Core symbology and is reported as `.unknown`.

Run tests: `cd Packages/Scanner && swift test` (macOS, logic only), or `xcodebuild test -scheme Scanner` on an iOS
simulator to also compile the camera UI.
