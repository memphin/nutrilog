import Core
import DesignSystem
import Persistence
import PhotosUI
import SwiftUI

/// "Snap or describe a meal": a photo and/or a sentence in, a reviewed list of foods out, logged in one tap.
struct SmartLogView: View {
    let target: AddTarget
    let onLogged: () -> Void
    /// Starts with this description and/or photo and estimates right away (debug screens).
    var prefilledText = ""
    var prefilledPhoto: Data?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model = SmartLogModel()
    @State private var slotID: String
    @State private var showCamera = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var estimation: Task<Void, Never>?
    @FocusState private var describing: Bool

    init(target: AddTarget, prefilledText: String = "", prefilledPhoto: Data? = nil, onLogged: @escaping () -> Void) {
        self.target = target
        self.onLogged = onLogged
        self.prefilledText = prefilledText
        self.prefilledPhoto = prefilledPhoto
        _slotID = State(initialValue: target.slotID)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .input: input
                case .working: working
                case .review: review
                }
            }
            .navigationTitle("Snap or describe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        estimation?.cancel()
                        dismiss()
                    }
                }
                if model.phase == .review {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(target.planned ? "Plan" : "Log") { log() }.disabled(!model.canLog)
                    }
                }
            }
            .task {
                guard !prefilledText.isEmpty || prefilledPhoto != nil, model.phase == .input, model.lines.isEmpty else { return }
                model.text = prefilledText
                model.jpeg = prefilledPhoto.flatMap { UIImage(data: $0) }.flatMap(MealPhoto.jpeg(from:))
                await model.estimate(in: environment)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    model.jpeg = MealPhoto.jpeg(from: image)
                }
                .ignoresSafeArea()
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        model.jpeg = MealPhoto.jpeg(from: image)
                    } else {
                        model.errorMessage = String(localized: "That photo couldn't be opened.")
                    }
                    pickedPhoto = nil
                }
            }
            .alert("Couldn't estimate", isPresented: Binding(get: { model.errorMessage != nil }, set: {
                if !$0 {
                    model.errorMessage = nil
                }
            })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
        }
    }

    // MARK: Input

    private var input: some View {
        Form {
            Section {
                if let jpeg = model.jpeg, let image = UIImage(data: jpeg) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("Photo of the meal")
                    Button("Remove photo", systemImage: "trash", role: .destructive) { model.jpeg = nil }
                } else {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take a photo", systemImage: "camera") { showCamera = true }
                    }
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Label("Choose a photo", systemImage: "photo")
                    }
                }
            }

            Section {
                TextField("2 eggs, toast with butter, coffee with milk", text: $model.text, axis: .vertical)
                    .lineLimit(2 ... 5)
                    .focused($describing)
            } header: {
                Text("Or describe it")
            } footer: {
                Text(engineNote)
            }

            Section {
                Button {
                    describing = false
                    estimation = Task { await model.estimate(in: environment) }
                } label: {
                    Label("Estimate", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canEstimate)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private var engineNote: String {
        let estimator = environment.mealEstimator
        if !estimator.isAvailable {
            return String(localized: """
            Apple Intelligence isn't available on this iPhone (or is turned off), so the text or photo is matched to \
            foods already on it. Nothing is sent anywhere.
            """)
        }
        return estimator.supportsPhotos
            ? String(localized: "Apple Intelligence estimates the foods, amounts and calories on this iPhone. Nothing is sent anywhere.")
            : String(localized: """
            Apple Intelligence estimates a description on this iPhone; estimating from a photo needs iOS 27. Nothing is \
            sent anywhere.
            """)
    }

    private var working: some View {
        VStack(spacing: NL.Spacing.m) {
            ProgressView()
            Text(environment.mealEstimator.isAvailable ? "Estimating…" : "Matching…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Review

    private var review: some View {
        Form {
            Section {
                ForEach($model.lines) { $line in
                    VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                        TextField("Name", text: $line.name).disabled(line.origin != .estimate)
                        HStack {
                            TextField("Amount", text: $line.amountText)
                                .keyboardType(.decimalPad)
                                .frame(maxWidth: 90)
                                .accessibilityLabel("Amount of \(line.name)")
                            Text(line.unit.symbol).foregroundStyle(.secondary)
                            Spacer()
                            Text(environment.energyUnit.format(line.nutrients.kcal)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { model.lines.remove(atOffsets: $0) }
            } header: {
                Text("Foods")
            } footer: {
                Text(model.notice ?? "")
            }

            Section {
                Picker("Meal", selection: $slotID) {
                    ForEach((try? environment.diary?.mealSlots()) ?? []) { Text($0.displayName).tag($0.id) }
                }
                NutrientRow(
                    String(localized: "Energy"), value: environment.energyUnit.display(model.totals.kcal),
                    unit: environment.energyUnit.symbol, emphasized: true,
                )
                MacroLine(protein: model.totals.proteinG, carbs: model.totals.carbsG, fat: model.totals.fatG)
            }

            Section {
                Button("Change the photo or text", systemImage: "arrow.uturn.backward") { model.editInput() }
            }
        }
    }

    private func log() {
        do {
            try model.log(slotID: slotID, day: target.day, planned: target.planned, in: environment)
            dismiss()
            onLogged()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
