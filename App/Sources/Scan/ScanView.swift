import DesignSystem
import Persistence
import Scanner
import SwiftUI

/// The barcode scanner screen opened from Add Food (backlog #20). The camera stays live underneath; the product
/// card, not-found and error screens open in a sheet over it. With "Keep scanning" on, logging returns to the
/// camera and the logged foods are counted (shopping-list style).
struct ScanView: View {
    let target: AddTarget
    /// Close the scanner and Add Food (a food was logged and continuous mode is off).
    let onFinished: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: ScanFlowModel?
    @State private var showSessionLog = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    scanner(model)
                } else {
                    Color.black
                }
            }
            .navigationTitle("Scan barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button((model?.loggedCount ?? 0) > 0 ? "Done" : "Close") { close() }
                }
                if let model {
                    ToolbarItem(placement: .primaryAction) {
                        Toggle(isOn: Binding(get: { model.keepScanning }, set: { model.keepScanning = $0 })) {
                            Label("Keep scanning", systemImage: "repeat")
                        }
                        .toggleStyle(.button)
                        .accessibilityHint("After logging a food, return to the camera instead of closing.")
                    }
                }
            }
        }
        .onAppear {
            if model == nil {
                model = ScanFlowModel(environment: environment)
            }
        }
    }

    private func scanner(_ model: ScanFlowModel) -> some View {
        // Pause the camera (and its haptics and torch) while a lookup runs or a sheet covers it.
        BarcodeScannerView(isPaused: model.showsResult || model.isResolving) { barcode in
            Task { await model.handle(barcode.candidates) }
        }
        .overlay(alignment: .top) { statusOverlay(model) }
        .sheet(isPresented: Binding(
            get: { model.showsResult },
            set: { presented in
                if !presented, model.showsResult {
                    model.resumeScanning()
                }
            },
        )) {
            ScanResultView(model: model, target: target, onFinished: finish)
                .environment(environment)
        }
        .sheet(isPresented: $showSessionLog) {
            SessionLogView(items: model.sessionLog)
        }
    }

    private func statusOverlay(_ model: ScanFlowModel) -> some View {
        VStack(spacing: NL.Spacing.s) {
            if model.isResolving {
                Label {
                    Text("Looking up…")
                } icon: {
                    ProgressView()
                }
                .padding(.horizontal, NL.Spacing.l)
                .padding(.vertical, NL.Spacing.s)
                .glassEffect()
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, NL.Spacing.l)
                    .padding(.vertical, NL.Spacing.s)
                    .glassEffect()
            }
            if model.loggedCount > 0 {
                Button { showSessionLog = true } label: {
                    Label("\(model.loggedCount) logged", systemImage: "checkmark.circle.fill")
                        .monospacedDigit()
                }
                .buttonStyle(.glass)
                .accessibilityHint("Shows the foods logged in this scanning session.")
            }
        }
        .padding(.top, NL.Spacing.m)
        .animation(.default, value: model.isResolving)
        .animation(.default, value: model.notice)
    }

    private func finish() {
        onFinished()
    }

    private func close() {
        dismiss()
    }
}

/// What was logged since the scanner opened.
private struct SessionLogView: View {
    let items: [ScanFlowModel.LoggedItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(items) { item in
                Label(item.name, systemImage: "checkmark.circle")
            }
            .navigationTitle("Logged this session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Sheet content over the camera: product card → quantity, not found, or lookup failure.
struct ScanResultView: View {
    let model: ScanFlowModel
    let target: AddTarget
    let onFinished: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var path: [FoodDetail] = []
    @State private var creating = false
    @State private var completing: CompletionRequest?
    @State private var errorMessage: String?
    /// The current food's label photo, read once per food rather than on every body pass.
    @State private var labelPhoto: (foodID: String, data: Data)?

    struct CompletionRequest: Identifiable {
        let id = UUID()
        let detail: FoodDetail
        let missing: Set<FoodEditorModel.RequiredNutrient>
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Scan another", systemImage: "barcode.viewfinder") { model.resumeScanning() }
                    }
                }
                .navigationDestination(for: FoodDetail.self) { detail in
                    QuantitySheet(detail: detail, mode: .log(slotID: target.slotID, day: target.day)) {
                        loggedFood(detail)
                    }
                }
        }
        .task(id: model.product.flatMap { $0.isSaved ? $0.food.id : nil }) {
            await loadLabelPhoto()
        }
        .sheet(isPresented: $creating) {
            FoodEditorView(barcode: model.barcodeForNewFood) { saved in
                model.foodCreated(saved)
            }
        }
        .sheet(item: $completing) { request in
            FoodEditorView(editing: request.detail, completing: request.missing) { saved in
                model.nutritionCompleted(saved)
            }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: {
            if !$0 {
                errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case let .found(product):
            ProductCardView(
                product: product,
                energyUnit: environment.energyUnit,
                labelPhoto: labelPhoto?.foodID == product.food.id ? labelPhoto?.data : nil,
                onLog: log,
                onCompleteNutrition: completeNutrition,
                onSetServingWeight: setServingWeight,
            )
            .navigationTitle(product.isSaved ? "Product" : "Open Food Facts")
            .navigationBarTitleDisplayMode(.inline)
        case let .notFound(barcode):
            NotFoundView(barcode: barcode, model: model) { creating = true }
                .navigationTitle("Not found")
                .navigationBarTitleDisplayMode(.inline)
        case let .failed(failure, candidates):
            LookupFailedView(
                failure: failure,
                barcode: candidates.first,
                isRetrying: model.isRetrying,
                onRetry: { Task { await model.retry() } },
                onCreate: { creating = true },
            )
            .navigationTitle("Not available")
            .navigationBarTitleDisplayMode(.inline)
        case .scanning, .resolving:
            ProgressView()
        }
    }

    private func loadLabelPhoto() async {
        guard let id = model.product.flatMap({ $0.isSaved ? $0.food.id : nil }) else {
            labelPhoto = nil
            return
        }
        let store = environment.labelPhotos
        let data = await Task.detached(priority: .utility) { store.load(foodID: id) }.value
        labelPhoto = data.map { (id, $0) }
    }

    private func log() {
        do {
            try path.append(model.foodForLogging())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func completeNutrition() {
        do {
            let food = try model.foodForCompletingNutrition()
            completing = CompletionRequest(detail: food.detail, missing: food.missing)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setServingWeight(_ amount: Double) {
        do {
            try model.setServingWeight(amount)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loggedFood(_ detail: FoodDetail) {
        switch model.didLog(detail) {
        case .keepScanning:
            path = []
        case .close:
            onFinished()
        }
    }
}
