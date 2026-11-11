import Core
import DesignSystem
import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// Settings: profile & targets, meal slots, Apple Health, units, data export/import, network, attributions (backlog #15).
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var stepGoal = StepGoal.defaultSteps
    @State private var sleepGoal = SleepGoal.defaultMinutes
    @State private var errorMessage: String?
    @State private var usdaKeyDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Profile & targets") { ProfileTargetsView() }
                    NavigationLink("Dashboard") { DashboardSettingsView() }
                    NavigationLink("Meal slots") { MealSlotsEditor() }
                    NavigationLink("Apple Health") { HealthSettingsView() }
                    NavigationLink("Weekly check-in") { CheckInSettingsView() }
                }

                Section("Units") {
                    Picker("Energy", selection: energyUnit) {
                        Text("Kilocalories (kcal)").tag(EnergyUnit.kcal)
                        Text("Kilojoules (kJ)").tag(EnergyUnit.kilojoules)
                    }
                }

                Section {
                    Stepper(value: $stepGoal, in: StepGoal.validRange, step: StepGoal.step) {
                        LabeledContent("Steps", value: stepGoal.formatted())
                    }
                    .onChange(of: stepGoal) { saveStepGoal() }
                    Stepper(value: $sleepGoal, in: SleepGoal.validRange, step: SleepGoal.step) {
                        LabeledContent("Sleep", value: DashboardFormat.duration(sleepGoal))
                    }
                    .onChange(of: sleepGoal) { saveSleepGoal() }
                    NavigationLink("Hydration") { HydrationSettingsView() }
                    NavigationLink("Caffeine") { CaffeineSettingsView() }
                } header: {
                    Text("Daily goals")
                } footer: {
                    Text(
                        "Steps and sleep are green on a day that reached the goal, orange close below it (sleep: up to an "
                            + "hour short) and red further away. Water is red far below the goal, orange from 80% of it and green once it is reached.",
                    )
                }

                Section {
                    NavigationLink("Export & import") { DataSettingsView() }
                    NavigationLink("Backups") { BackupsView() }
                    NavigationLink("Duplicate foods") { DuplicateFoodsView() }
                } header: {
                    Text("Your data")
                } footer: {
                    Text(
                        "Everything is stored only on this iPhone. A backup is kept on it every week; export regularly to "
                            + "have a copy somewhere else too.",
                    )
                }

                Section {
                    usdaKeyRows
                    NavigationLink("Network access") { NetworkInfoView() }
                } header: {
                    Text("Food sources")
                } footer: {
                    Text(usdaKeyFooter)
                }

                Section("Diagnostics") {
                    NavigationLink("Barcode resolution") { BarcodeResolutionView() }
                }

                Section {
                    NavigationLink("About & licenses") { AboutView() }
                }
            }
            .navigationTitle("Settings")
            // Re-read after an import replaced the data.
            .task(id: environment.dataGeneration) {
                stepGoal = environment.profiles.map(StepGoal.load(from:)) ?? StepGoal.defaultSteps
                sleepGoal = environment.profiles.map(SleepGoal.load(from:)) ?? SleepGoal.defaultMinutes
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: {
                if !$0 {
                    errorMessage = nil
                }
            })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    /// "USDA API key": a secure field with Save, or the saved key's status with Remove.
    @ViewBuilder private var usdaKeyRows: some View {
        if environment.usdaKeySource == .keychain {
            LabeledContent("USDA API key", value: "Saved")
            Button("Remove USDA API key", role: .destructive) { removeUSDAKey() }
        } else if environment.usdaKeychainUnreadable {
            // A key may be stored but can't be read yet: don't offer an empty field that looks like "no key".
            LabeledContent("USDA API key", value: "Keychain locked")
        } else {
            SecureField("USDA API key", text: $usdaKeyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { saveUSDAKey() }
            Button("Save USDA API key") { saveUSDAKey() }
                .disabled(usdaKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var usdaKeyFooter: String {
        if environment.usdaKeySource != .keychain, environment.usdaKeychainUnreadable {
            return "If you saved a USDA API key, it can't be read until this iPhone is unlocked. It then loads automatically."
        }
        return switch environment.usdaKeySource {
        case .keychain:
            "Online USDA FoodData Central search uses your key, stored in this iPhone's Keychain."
        case .buildConfig:
            "Online USDA FoodData Central search uses the key built into this version. Save your own to use it instead."
        case .none:
            "Optional. With a free key from api.data.gov you can also search USDA FoodData Central online. "
                + "It's stored only in this iPhone's Keychain."
        }
    }

    private func saveUSDAKey() {
        do {
            try environment.saveUSDAKey(usdaKeyDraft)
            usdaKeyDraft = ""
        } catch {
            errorMessage = "Couldn't save the USDA API key: \(error.localizedDescription)"
        }
    }

    private func removeUSDAKey() {
        do {
            try environment.removeUSDAKey()
        } catch {
            errorMessage = "Couldn't remove the USDA API key: \(error.localizedDescription)"
        }
    }

    private var energyUnit: Binding<EnergyUnit> {
        Binding(get: { environment.energyUnit }, set: { unit in
            do {
                try environment.setEnergyUnit(unit)
            } catch {
                errorMessage = "Couldn't save the energy unit: \(error.localizedDescription)"
            }
        })
    }

    private func saveStepGoal() {
        guard let profiles = environment.profiles, StepGoal.load(from: profiles) != stepGoal else { return }
        do {
            try StepGoal.save(stepGoal, to: profiles)
        } catch {
            errorMessage = "Couldn't save the step goal: \(error.localizedDescription)"
        }
    }

    private func saveSleepGoal() {
        guard let profiles = environment.profiles, SleepGoal.load(from: profiles) != sleepGoal else { return }
        do {
            try SleepGoal.save(sleepGoal, to: profiles)
        } catch {
            errorMessage = "Couldn't save the sleep goal: \(error.localizedDescription)"
        }
    }
}

// MARK: - Meal slots

struct MealSlotsEditor: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var slots: [MealSlot] = []
    @State private var loaded = false
    @State private var errorMessage: String?

    /// Every slot has a name and at least one is active; otherwise nothing is saved.
    private var isValid: Bool {
        !slots.contains { $0.name.trimmingCharacters(in: .whitespaces).isEmpty } && slots.contains(where: \.isActive)
    }

    var body: some View {
        List {
            Section {
                ForEach($slots) { $slot in
                    HStack {
                        TextField("Name", text: $slot.name)
                            .foregroundStyle(slot.isActive ? .primary : .secondary)
                        Toggle("Active", isOn: $slot.isActive).labelsHidden()
                    }
                    .accessibilityElement(children: .contain)
                }
                .onMove { slots.move(fromOffsets: $0, toOffset: $1) }
                Button("Add meal slot", systemImage: "plus") {
                    slots.append(MealSlot(name: "New meal", sortOrder: slots.count))
                }
            } footer: {
                Text("Drag to reorder. Inactive slots are hidden but keep their past entries.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Meal slots")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isValid)
            }
        }
        // Once: coming back to the screen (another tab and back) must not overwrite edits with the stored slots.
        .task {
            guard !loaded else { return }
            slots = (try? environment.diary?.mealSlots(includeInactive: true)) ?? []
            loaded = true
        }
        // Like every other settings screen, leaving keeps the changes — when they can be saved.
        .onDisappear {
            if loaded, isValid {
                save()
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

    private func save() {
        do {
            let trimmed = slots.map { slot -> MealSlot in
                var copy = slot
                copy.name = slot.name.trimmingCharacters(in: .whitespaces)
                return copy
            }
            // The array order becomes `sortOrder`, so reordering is saved too.
            try environment.profiles?.saveMealSlots(trimmed)
            slots = try (environment.diary?.mealSlots(includeInactive: true)) ?? trimmed
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Export / import

struct DataSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var exportFiles: [URL] = []
    @State private var showImporter = false
    @State private var pendingImport: Data?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button("Prepare export", systemImage: "square.and.arrow.up") { prepareExport() }
                if !exportFiles.isEmpty {
                    ShareLink(items: exportFiles) {
                        Label("Share \(exportFiles.count) files", systemImage: "square.and.arrow.up.on.square")
                    }
                    ForEach(exportFiles, id: \.self) { Text($0.lastPathComponent).font(.footnote).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Export")
            } footer: {
                Text("JSON contains everything and can be restored. CSV (diary, weights) opens in Numbers or Excel.")
            }

            Section {
                Button("Import from JSON…", systemImage: "square.and.arrow.down") { showImporter = true }
            } header: {
                Text("Import")
            } footer: {
                Text("Merge keeps the newer version of each record. Replace deletes everything on this phone first.")
            }
        }
        .navigationTitle("Export & import")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do { pendingImport = try Data(contentsOf: url) } catch { message = error.localizedDescription }
            case let .failure(error):
                message = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Import data",
            isPresented: Binding(get: { pendingImport != nil }, set: {
                if !$0 {
                    pendingImport = nil
                }
            }),
            titleVisibility: .visible,
            // The buttons get the file as presented: the binding's setter may already have cleared `pendingImport`.
            presenting: pendingImport,
        ) { data in
            Button("Merge with my data") { runImport(data, mode: .merge) }
            Button("Replace all my data", role: .destructive) { runImport(data, mode: .replace) }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: { _ in
            Text("How should the file be imported?")
        }
        .alert("Export & import", isPresented: Binding(get: { message != nil }, set: {
            if !$0 {
                message = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func prepareExport() {
        guard let portability = environment.portability else { return }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = environment.today.isoString
            let json = dir.appendingPathComponent("vitalion-\(stamp).json")
            try portability.exportJSON().write(to: json)
            var files = [json]
            for (name, content) in try portability.exportCSV().sorted(by: { $0.key < $1.key }) {
                let url = dir.appendingPathComponent("vitalion-\(stamp)-\(name)")
                try Data(content.utf8).write(to: url)
                files.append(url)
            }
            exportFiles = files
        } catch {
            message = error.localizedDescription
        }
    }

    private func runImport(_ data: Data, mode: DataPortability.ImportMode) {
        pendingImport = nil
        guard let portability = environment.portability else { return }
        // Keep the current data recoverable (Settings → Backups). A replace doesn't go ahead without that backup; a
        // merge only adds or updates records, so it does, and says so.
        var backupFailure: String?
        do {
            try environment.backups?.backupNow()
        } catch {
            guard mode == .merge else {
                message = "Nothing was imported: the backup of your current data couldn't be written. \(error.localizedDescription)"
                return
            }
            backupFailure = error.localizedDescription
        }
        do {
            let summary = try portability.importJSON(data, mode: mode)
            message = "Imported: \(summary.inserted) new, \(summary.updated) updated, \(summary.skipped) unchanged."
            if let backupFailure {
                message = (message ?? "") + " No backup of the previous data was made: \(backupFailure)"
            }
            do {
                // Settings cached in memory and pending undo actions may not match the imported data.
                try environment.dataDidChangeExternally()
            } catch {
                message = "Imported, but the settings couldn't be reloaded: \(error.localizedDescription)"
            }
        } catch DataPortability.ImportError.newerSchema {
            message = "This file was made by a newer version of Vitalion. Update the app first."
        } catch DataPortability.ImportError.notAnExport {
            message = "This isn't a Vitalion export file."
        } catch DataPortability.ImportError.incompleteBackup {
            message = "This file is incomplete (no profile or meal slots), so nothing was replaced. Try Merge instead."
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Network & about

struct NetworkInfoView: View {
    struct Host {
        let host: String
        let requests: [(path: String, purpose: String)]
        let sent: String
    }

    /// Every request the app makes (PRIVACY.md "What leaves the device").
    static let hosts: [Host] = [
        Host(
            host: "world.openfoodfacts.org",
            requests: [
                ("/api/v2/product/{barcode}.json", "Product lookup when a barcode isn't in the local cache"),
                ("/cgi/search.pl", "Packaged-food search in Add Food → Online"),
            ],
            sent: "The barcode or the search text, and a User-Agent naming the app (Vitalion and its version). No account.",
        ),
        Host(
            host: "images.openfoodfacts.org",
            requests: [
                ("/images/products/…", "Product photo on the scanned product's card"),
            ],
            sent: "The image address only (it names the product's barcode).",
        ),
        Host(
            host: "api.nal.usda.gov",
            requests: [
                ("/fdc/v1/foods/search", "Generic and branded food search in Add Food → Online — only with a USDA API key"),
            ],
            sent: "The search text and your API key (in a request header, never stored in a cache).",
        ),
    ]

    var body: some View {
        List {
            ForEach(Self.hosts, id: \.host) { item in
                Section {
                    ForEach(item.requests, id: \.path) { request in
                        VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                            Text(request.path).font(.footnote.monospaced())
                            Text(request.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(item.host).font(.body.monospaced()).textCase(nil)
                } footer: {
                    Text("Sent: \(item.sent)")
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text(
                    "These are the only hosts Vitalion contacts, and only when you scan a barcode or search online. "
                        + "No analytics, no tracking, no accounts.",
                )
            }
        }
        .navigationTitle("Network access")
    }
}

struct AboutView: View {
    static let offAttribution = "Contains information from Open Food Facts, contributed by Open Food Facts contributors, which is made available here under the Open Database License (ODbL)."
    static let usdaAttribution = "U.S. Department of Agriculture, Agricultural Research Service. FoodData Central. fdc.nal.usda.gov — public domain (CC0 1.0)."

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Link("Source code on GitHub", destination: URL(string: "https://github.com/memphin/vitalion")!)
            }
            Section("Data sources") {
                Text(Self.offAttribution).font(.footnote)
                Text(Self.usdaAttribution).font(.footnote)
            }
            Section("Open-source licenses") {
                VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                    Text("Vitalion").bold()
                    Text("MIT License © 2026 Ivan Juric").font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                    Text("GRDB.swift").bold()
                    Text("MIT License © Gwendal Roué").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Vitalion is not a medical device and provides no medical advice.").font(.footnote)
            }
        }
        .navigationTitle("About")
    }
}
