import Core
import DesignSystem
import Persistence
import PhotosUI
import SwiftUI

/// The product card after a scan (FR-12): image, name, brand, Nutri-Score, per-100 and per-serving values,
/// data-quality warning with "Complete nutrition", stale-cache notice, then Log.
struct ProductCardView: View {
    let product: ScannedProduct
    let energyUnit: EnergyUnit
    var labelPhoto: Data?
    let onLog: () -> Void
    let onCompleteNutrition: () -> Void
    let onSetServingWeight: (Double) -> Void

    @State private var servingWeightText = ""
    @FocusState private var servingWeightFocused: Bool

    private var food: Food {
        product.food
    }

    private var unit: String {
        food.baseUnit.symbol
    }

    var body: some View {
        Form {
            Section {
                header
            }

            if product.isStale, let fetchedAt = product.remote?.fetchedAt {
                Section {
                    Label {
                        Text("Offline: showing the copy saved \(fetchedAt.formatted(.relative(presentation: .named))). It may be outdated.")
                    } icon: {
                        Image(systemName: "wifi.slash")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if product.needsServingWeight {
                servingWeightSection
            }

            if product.needsCompletion {
                Section {
                    Label(qualityWarning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Complete nutrition", systemImage: "square.and.pencil", action: onCompleteNutrition)
                }
            }

            if let per100 = product.per100 {
                nutrientSection("Per 100 \(unit)", per100)
            }
            if let serving = product.serving {
                nutrientSection(Self.servingTitle(label: serving.label, amount: serving.amount, unit: unit), serving.nutrients)
            }

            if let labelPhoto, let image = UIImage(data: labelPhoto) {
                Section("Label photo") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .accessibilityLabel("Your photo of the nutrition label")
                }
            }

            if product.remote != nil {
                Section {
                    Text("Data from Open Food Facts (ODbL). Saved to your foods when you log it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onLog) {
                Text("Log").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, NL.Spacing.l)
            .padding(.bottom, NL.Spacing.s)
        }
    }

    /// "Per 1 portion (30 g)": the serving label, with its weight appended unless the label already states it
    /// ("30 g", "1 portion (30g)", "2 biscuits 25,5 g"), so it doesn't read "Per 30 g (30 g)". When the label's
    /// amount can't be matched, the weight is appended: a repeat is better than hiding the only weight.
    static func servingTitle(label: String, amount: Double?, unit: String) -> String {
        guard let amount else { return "Per \(label)" }
        if labelStates(amount, unit: unit, in: label) {
            return "Per \(label)"
        }
        return "Per \(label) (\(NutrientRow.format(amount, unit: unit)) \(unit))"
    }

    /// Amounts with a unit written in serving labels, e.g. "30 g", "30g", "25,5 ml", "33 cl".
    private static let labelAmountPattern = try? NSRegularExpression(
        pattern: #"(?<![\d.,])(\d+(?:[.,]\d+)?)\s*(grams|gram|gr|g|kg|ml|cl|l)(?![a-z])"#,
        options: [.caseInsensitive],
    )

    /// Whether `label` contains `amount` in `unit` ("g" or "ml"), allowing for label rounding.
    static func labelStates(_ amount: Double, unit: String, in label: String) -> Bool {
        guard let pattern = labelAmountPattern, amount > 0, amount.isFinite else { return false }
        let text = label as NSString
        for match in pattern.matches(in: label, range: NSRange(location: 0, length: text.length)) where match.numberOfRanges == 3 {
            let number = text.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")
            guard let value = Double(number) else { continue }
            let factor: Double? = switch (text.substring(with: match.range(at: 2)).lowercased(), unit) {
            case ("g", "g"), ("gr", "g"), ("gram", "g"), ("grams", "g"), ("ml", "ml"): 1
            case ("kg", "g"), ("l", "ml"): 1000
            case ("cl", "ml"): 10
            default: nil
            }
            guard let factor else { continue }
            if abs(value * factor - amount) <= max(0.01, amount * 0.005) {
                return true
            }
        }
        return false
    }

    private var header: some View {
        HStack(alignment: .top, spacing: NL.Spacing.m) {
            AsyncImage(url: product.imageURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "takeoutbag.and.cup.and.straw")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: NL.Radius.s))
            .clipShape(RoundedRectangle(cornerRadius: NL.Radius.s))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                Text(food.name).font(.headline)
                if let brand = food.brand, !brand.isEmpty {
                    Text(brand).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: NL.Spacing.s) {
                    SourceBadge(food.source.badge)
                    if let grade = product.nutriscore {
                        NutriScoreBadge(grade: grade)
                    }
                }
                if let barcode = product.barcode {
                    Text(barcode).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private var servingWeightSection: some View {
        Section {
            HStack {
                TextField("Serving weight", text: $servingWeightText)
                    .keyboardType(.decimalPad)
                    .focused($servingWeightFocused)
                Text(unit).foregroundStyle(.secondary)
                Button("Set") {
                    if let amount = Format.number(servingWeightText), amount > 0 {
                        servingWeightFocused = false
                        onSetServingWeight(amount)
                    }
                }
                .disabled((Format.number(servingWeightText) ?? 0) <= 0)
            }
        } header: {
            Text("Serving weight unknown")
        } footer: {
            Text("This product only lists values per serving. Enter the serving weight from the pack to log it in \(unit) "
                + "too; until then it can be logged by servings only.")
        }
    }

    private var qualityWarning: String {
        switch food.dataQuality {
        case .energyOnly: "Only the energy is known for this product."
        case .partialMacros, .complete: "Some nutrients are missing for this product."
        }
    }

    private func nutrientSection(_ title: String, _ n: Nutrients) -> some View {
        Section(title) {
            NutrientRow(
                "Energy",
                value: product.isMissing(.energy) ? nil : energyUnit.display(n.kcal),
                unit: energyUnit.symbol,
                emphasized: true,
            )
            NutrientRow("Protein", value: product.isMissing(.protein) ? nil : n.proteinG)
            NutrientRow("Carbohydrates", value: product.isMissing(.carbs) ? nil : n.carbsG)
            if let sugar = n.sugarG {
                NutrientRow("of which sugars", value: sugar, indent: true)
            }
            if let fiber = n.fiberG {
                NutrientRow("Fiber", value: fiber)
            }
            NutrientRow("Fat", value: product.isMissing(.fat) ? nil : n.fatG)
            if let sat = n.satFatG {
                NutrientRow("of which saturated", value: sat, indent: true)
            }
            if let sodium = n.sodiumMg {
                NutrientRow("Salt", value: Salt.saltG(fromSodiumMg: sodium))
            }
        }
    }
}

/// Nutri-Score letter in its official color.
struct NutriScoreBadge: View {
    let grade: String

    private var color: Color {
        switch grade {
        case "A": Color(red: 0.0, green: 0.51, blue: 0.25)
        case "B": Color(red: 0.52, green: 0.73, blue: 0.18)
        case "C": Color(red: 0.93, green: 0.73, blue: 0.0)
        case "D": Color(red: 0.89, green: 0.45, blue: 0.08)
        default: Color(red: 0.89, green: 0.24, blue: 0.10)
        }
    }

    var body: some View {
        Text("Nutri-Score \(grade)")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, NL.Spacing.s - 2)
            .padding(.vertical, NL.Spacing.xxs)
            // Dark text on the light B/C greens and yellow, white on the rest (contrast).
            .foregroundStyle(grade == "B" || grade == "C" ? Color.black : Color.white)
            .background(color, in: Capsule())
            .accessibilityLabel("Nutri-Score \(grade)")
    }
}

/// Nobody knows the code (FR-13): create the food with the barcode prefilled; optionally photograph the label first.
struct NotFoundView: View {
    let barcode: String
    @Bindable var model: ScanFlowModel
    let onCreate: () -> Void

    var body: some View {
        Form {
            Section {
                ContentUnavailableView {
                    Label("Product not found", systemImage: "barcode")
                } description: {
                    Text("\(barcode) isn't in your foods or on Open Food Facts. Create it from the label: next time this "
                        + "barcode is scanned it is found instantly, even offline.")
                } actions: {
                    Button("Create food", systemImage: "plus", action: onCreate)
                        .buttonStyle(.glassProminent)
                }
            }
            LabelPhotoSection(photo: $model.pendingLabelPhoto)
        }
    }
}

/// The lookup failed: say why, retry, or create the food by hand.
struct LookupFailedView: View {
    let failure: ScanFlowModel.Failure
    let barcode: String?
    var isRetrying = false
    let onRetry: () -> Void
    let onCreate: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: failure == .offline ? "wifi.slash" : "exclamationmark.icloud")
        } description: {
            VStack(spacing: NL.Spacing.s) {
                Text(failure.message)
                if let barcode {
                    Text(barcode).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        } actions: {
            if isRetrying {
                ProgressView("Trying again…")
            } else {
                Button("Try again", systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.glassProminent)
            }
            Button("Create food manually", systemImage: "plus", action: onCreate)
                .disabled(isRetrying)
        }
    }
}

/// Optional photo of the nutrition label, kept on this device for reference (FR-13). Camera when available,
/// otherwise the photo library.
struct LabelPhotoSection: View {
    @Binding var photo: Data?
    @State private var showCamera = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var loadError: String?

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        Section {
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .accessibilityLabel("Label photo")
                Button("Remove photo", systemImage: "trash", role: .destructive) { self.photo = nil }
            }
            if isProcessing {
                ProgressView()
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if cameraAvailable {
                Button(photo == nil ? "Photograph label" : "Retake photo", systemImage: "camera") { showCamera = true }
            }
            PhotosPicker(selection: $libraryItem, matching: .images) {
                Label("Choose from library", systemImage: "photo.on.rectangle")
            }
        } header: {
            Text("Label photo (optional)")
        } footer: {
            Text("Kept only on this iPhone, as a reference for the values you type in.")
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                process { image.jpegData(compressionQuality: 0.9) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            libraryItem = nil
            isProcessing = true
            loadError = nil
            Task {
                do {
                    let data = try await item.loadTransferable(type: Data.self)
                    process { data }
                } catch {
                    isProcessing = false
                    loadError = "Couldn't load that photo: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Encodes and downsamples off the main actor, then shows the result (or says why it failed).
    private func process(_ makeData: @escaping @Sendable () -> Data?) {
        isProcessing = true
        loadError = nil
        Task {
            let jpeg = await Task.detached(priority: .userInitiated) {
                makeData().flatMap { LabelPhotoStore.downsampledJPEG($0) }
            }.value
            isProcessing = false
            if let jpeg {
                photo = jpeg
            } else {
                loadError = "Couldn't read that photo. Try another one."
            }
        }
    }
}

/// `UIImagePickerController` with the camera (SwiftUI has no camera capture view). Also used by Smart log.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any],
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
