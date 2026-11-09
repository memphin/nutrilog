#if os(iOS)
    import SwiftUI

    /// Manual barcode entry for damaged or unreadable codes (FR-14). Submits only codes whose check digit is valid.
    public struct ManualBarcodeEntryView: View {
        private let onSubmit: @MainActor (ScannedBarcode) -> Void
        @State private var text = ""
        @FocusState private var isFocused: Bool

        public init(onSubmit: @escaping @MainActor (ScannedBarcode) -> Void) {
            self.onSubmit = onSubmit
        }

        private var validation: ManualBarcodeValidation {
            ManualBarcodeValidation(text)
        }

        public var body: some View {
            Form {
                Section {
                    TextField("Barcode digits", text: $text)
                        .keyboardType(.numberPad)
                        .textContentType(.none)
                        .autocorrectionDisabled()
                        .font(.body.monospacedDigit())
                        .focused($isFocused)
                        .onSubmit(submit)
                        .accessibilityIdentifier("manualBarcodeField")
                } footer: {
                    if let message = validation.message {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Type the 8, 12, 13 or 14 digits printed under the barcode.")
                    }
                }
                Section {
                    Button("Use Barcode", action: submit)
                        .disabled(validation.barcode == nil)
                        .accessibilityIdentifier("manualBarcodeSubmit")
                }
            }
            .navigationTitle("Enter Barcode")
            .onAppear { isFocused = true }
        }

        private func submit() {
            guard let barcode = validation.barcode else { return }
            onSubmit(barcode)
        }
    }
#endif
