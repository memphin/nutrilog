import Core
import DesignSystem
import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// Settings: profile & targets, meal slots, units, data export/import, network, attributions (backlog #15).
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var waterGoal = 2500.0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Profile & targets") { ProfileTargetsView() }
                    NavigationLink("Meal slots") { MealSlotsEditor() }
                }

                Section("Units") {
                    Picker("Energy", selection: energyUnit) {
                        Text("Kilocalories (kcal)").tag(EnergyUnit.kcal)
                        Text("Kilojoules (kJ)").tag(EnergyUnit.kilojoules)
                    }
                    Stepper(value: $waterGoal, in: 500 ... 6000, step: 250) {
                        LabeledContent("Daily water goal", value: "\(Int(waterGoal)) ml")
                    }
                    .onChange(of: waterGoal) { saveWaterGoal() }
                }

                Section {
                    NavigationLink("Export & import") { DataSettingsView() }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Everything is stored only on this iPhone. Export regularly to keep a backup.")
                }

                Section {
                    LabeledContent(
                        "USDA FoodData Central",
                        value: environment.config.usdaAPIKey == nil ? "No key (optional)" : "Key configured",
                    )
                    NavigationLink("Network access") { NetworkInfoView() }
                } header: {
                    Text("Food sources")
                }

                Section {
                    NavigationLink("About & licenses") { AboutView() }
                }
            }
            .navigationTitle("Settings")
            // Re-read after an import replaced the data.
            .task(id: environment.dataGeneration) {
                waterGoal = (try? environment.profiles?.profile().waterGoalMl) ?? 2500
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

    private var energyUnit: Binding<EnergyUnit> {
        Binding(get: { environment.energyUnit }, set: { unit in
            do {
                try environment.setEnergyUnit(unit)
            } catch {
                errorMessage = "Couldn't save the energy unit: \(error.localizedDescription)"
            }
        })
    }

    private func saveWaterGoal() {
        guard let profiles = environment.profiles else { return }
        do {
            var profile = try profiles.profile()
            guard profile.waterGoalMl != waterGoal else { return }
            profile.waterGoalMl = waterGoal
            try profiles.save(profile)
        } catch {
            errorMessage = "Couldn't save the water goal: \(error.localizedDescription)"
        }
    }
}

// MARK: - Meal slots

struct MealSlotsEditor: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var slots: [MealSlot] = []
    @State private var errorMessage: String?

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
                    .disabled(slots.contains { $0.name.trimmingCharacters(in: .whitespaces).isEmpty } || !slots.contains(where: \.isActive))
            }
        }
        .task { slots = (try? environment.diary?.mealSlots(includeInactive: true)) ?? [] }
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
        ) {
            Button("Merge with my data") { runImport(.merge) }
            Button("Replace all my data", role: .destructive) { runImport(.replace) }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
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
            let json = dir.appendingPathComponent("nutrilog-\(stamp).json")
            try portability.exportJSON().write(to: json)
            var files = [json]
            for (name, content) in try portability.exportCSV().sorted(by: { $0.key < $1.key }) {
                let url = dir.appendingPathComponent("nutrilog-\(stamp)-\(name)")
                try Data(content.utf8).write(to: url)
                files.append(url)
            }
            exportFiles = files
        } catch {
            message = error.localizedDescription
        }
    }

    private func runImport(_ mode: DataPortability.ImportMode) {
        guard let data = pendingImport, let portability = environment.portability else { return }
        pendingImport = nil
        do {
            let summary = try portability.importJSON(data, mode: mode)
            message = "Imported: \(summary.inserted) new, \(summary.updated) updated, \(summary.skipped) unchanged."
            do {
                // Settings cached in memory and pending undo actions may not match the imported data.
                try environment.dataDidChangeExternally()
            } catch {
                message = "Imported, but the settings couldn't be reloaded: \(error.localizedDescription)"
            }
        } catch DataPortability.ImportError.newerSchema {
            message = "This file was made by a newer version of Nutrilog. Update the app first."
        } catch DataPortability.ImportError.notAnExport {
            message = "This isn't a Nutrilog export file."
        } catch DataPortability.ImportError.incompleteBackup {
            message = "This file is incomplete (no profile or meal slots), so nothing was replaced. Try Merge instead."
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Network & about

struct NetworkInfoView: View {
    static let hosts: [(host: String, purpose: String)] = [
        ("world.openfoodfacts.org", "Product lookup by barcode and packaged-food search (phase 2)"),
        ("api.nal.usda.gov", "USDA FoodData Central search — only with your own API key (phase 2)"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.hosts, id: \.host) { item in
                    VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                        Text(item.host).font(.body.monospaced())
                        Text(item.purpose).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(
                    "These are the only hosts Nutrilog ever contacts. No analytics, no tracking, no accounts. This version makes no network requests at all.",
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
                Link("Source code on GitHub", destination: URL(string: "https://github.com/memphin/nutrilog")!)
            }
            Section("Data sources") {
                Text(Self.offAttribution).font(.footnote)
                Text(Self.usdaAttribution).font(.footnote)
            }
            Section("Open-source licenses") {
                VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                    Text("Nutrilog").bold()
                    Text("MIT License © 2026 Ivan Juric").font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: NL.Spacing.xs) {
                    Text("GRDB.swift").bold()
                    Text("MIT License © Gwendal Roué").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Nutrilog is not a medical device and provides no medical advice.").font(.footnote)
            }
        }
        .navigationTitle("About")
    }
}
