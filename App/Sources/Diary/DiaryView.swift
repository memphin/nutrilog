import Core
import DesignSystem
import Persistence
import SwiftUI

/// Day view with meal slots, summary header, date navigation and copy actions (backlog #7, #12).
struct DiaryView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: DiaryModel?

    var body: some View {
        NavigationStack {
            if let model {
                DiaryContent(model: model)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil {
                model = DiaryModel(environment: environment)
            }
        }
    }
}

/// What the add-food sheet is opened for.
struct AddTarget: Identifiable {
    let slotID: String
    let day: LocalDay
    var id: String {
        "\(day)-\(slotID)"
    }
}

private struct DiaryContent: View {
    @Bindable var model: DiaryModel
    @Environment(AppEnvironment.self) private var environment

    @State private var addTarget: AddTarget?
    @State private var quickAddTarget: AddTarget?
    @State private var editing: DiaryEntry?
    @State private var copyRequest: CopyRequest?
    @State private var showDatePicker = false
    @State private var showNoteEditor = false
    @State private var movingEntry: DiaryEntry?
    @State private var savingMealSlot: MealSlot?
    @State private var mealName = ""

    struct CopyRequest: Identifiable {
        let slotID: String?
        var id: String {
            slotID ?? "day"
        }
    }

    var body: some View {
        List {
            Section {
                DaySummaryHeader(totals: model.diary?.totals ?? .zero, target: model.target, unit: model.energyUnit)
                    .listRowInsets(EdgeInsets(top: NL.Spacing.m, leading: NL.Spacing.l, bottom: NL.Spacing.m, trailing: NL.Spacing.l))
                    .gesture(daySwipe)
            }

            if let diary = model.diary {
                ForEach(diary.sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            EntryRow(
                                entry: entry,
                                unit: model.energyUnit,
                                isLiquid: entry.foodID.map(model.liquidFoodIDs.contains) ?? false,
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { editing = entry }
                            .contextMenu { entryMenu(entry) }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) { model.delete([entry]) }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(entry) }
                                    .tint(.blue)
                            }
                        }
                        .onMove { model.reorder(in: section, from: $0, to: $1) }
                        Button {
                            addTarget = AddTarget(slotID: section.slot.id, day: model.day)
                        } label: {
                            Label("Add food", systemImage: "plus")
                        }
                        .accessibilityLabel("Add food to \(section.slot.name)")
                    } header: {
                        sectionHeader(section)
                    }
                }

                Section("Notes") {
                    Button {
                        showNoteEditor = true
                    } label: {
                        if let note = diary.note, !note.text.isEmpty {
                            Text(note.text).foregroundStyle(.primary)
                        } else {
                            Label("Add a note for this day", systemImage: "square.and.pencil")
                        }
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { diary.note?.isComplete == true }, set: { _ in model.toggleComplete() })) {
                        Label("Day fully logged", systemImage: "checkmark.seal")
                    }
                    if let hint = model.loggingHint {
                        Label {
                            Text(hint).font(.footnote).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text("The maintenance estimate uses days that are fully logged or have at least 3 entries.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Format.day(model.day, today: model.today))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: model.day) { await model.observeDiary() }
        .task(id: model.day) { await model.observeTarget() }
        .task(id: model.day) { model.reloadEstimate() }
        .onChange(of: environment.dataGeneration) { model.dataDidChangeExternally() }
        // The history calendar (or anything else) asked for a day.
        .onChange(of: environment.diaryDayRequest, initial: true) { _, requested in
            if let requested {
                model.day = requested
                environment.diaryDayRequest = nil
            }
        }
        .alert("Save as meal", isPresented: Binding(get: { savingMealSlot != nil }, set: {
            if !$0 {
                savingMealSlot = nil
            }
        })) {
            TextField("Name", text: $mealName)
            Button("Save") {
                if let slot = savingMealSlot {
                    model.saveAsMeal(slotID: slot.id, name: mealName)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the foods of this meal so you can log them all at once from Add food → Meals.")
        }
        .undoToast(model.undo)
        .sheet(item: $addTarget) { target in
            AddFoodView(target: target)
        }
        .sheet(item: $quickAddTarget) { target in
            QuickAddView(mode: .create(slotID: target.slotID, day: target.day))
        }
        .sheet(item: $editing) { entry in
            EditEntryView(entry: entry)
        }
        .sheet(item: $copyRequest) { request in
            CopyFromDateSheet(defaultDay: model.day.previous, title: request.slotID == nil ? "Copy whole day" : "Copy meal") { source in
                model.copy(from: source, slotID: request.slotID)
            }
        }
        .sheet(item: $movingEntry) { entry in
            MoveToDateSheet(entry: entry, slots: model.moveTargets(for: entry)) { slotID, day in
                model.move(entry, toSlot: slotID, day: day)
            }
        }
        .sheet(isPresented: $showDatePicker) {
            DayPickerSheet(day: $model.day)
        }
        .sheet(isPresented: $showNoteEditor) {
            DayNoteEditor(note: model.diary?.note) { text, complete in
                model.saveNote(text: text, isComplete: complete)
            }
        }
        .alert("Diary", isPresented: Binding(get: { model.errorMessage != nil }, set: {
            if !$0 {
                model.errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Pieces

    private func sectionHeader(_ section: DayDiary.Section) -> some View {
        HStack {
            Text(section.slot.name)
            Spacer()
            if !section.entries.isEmpty {
                Text(model.energyUnit.format(section.totals.kcal))
                    .monospacedDigit()
            }
            Menu {
                Button("Add food", systemImage: "plus") { addTarget = AddTarget(slotID: section.slot.id, day: model.day) }
                Button("Quick add calories", systemImage: "bolt") { quickAddTarget = AddTarget(slotID: section.slot.id, day: model.day) }
                Divider()
                Button("Save as meal…", systemImage: "square.and.arrow.down.on.square") {
                    mealName = section.slot.name
                    savingMealSlot = section.slot
                }
                .disabled(!section.entries.contains { !$0.isQuickAdd })
                Button("Copy from yesterday", systemImage: "arrow.uturn.backward") {
                    model.copy(from: model.day.previous, slotID: section.slot.id)
                }
                Button("Copy from date…", systemImage: "calendar") { copyRequest = CopyRequest(slotID: section.slot.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .accessibilityLabel("\(section.slot.name) options")
            }
        }
    }

    @ViewBuilder
    private func entryMenu(_ entry: DiaryEntry) -> some View {
        Button("Edit", systemImage: "pencil") { editing = entry }
        Menu("Move to", systemImage: "arrow.right.square") {
            ForEach(model.slots.filter { $0.id != entry.mealSlotID }) { slot in
                Button(slot.name) { model.move(entry, toSlot: slot.id) }
            }
            Divider()
            Button("Another day…", systemImage: "calendar") { movingEntry = entry }
        }
        Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(entry) }
        Button("Delete", systemImage: "trash", role: .destructive) { model.delete([entry]) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("Previous day", systemImage: "chevron.left") { model.goToPreviousDay() }
            Button("Next day", systemImage: "chevron.right") { model.goToNextDay() }
        }
        ToolbarItem(placement: .principal) {
            Button {
                showDatePicker = true
            } label: {
                Text(Format.day(model.day, today: model.today)).font(.headline)
            }
            .accessibilityHint("Choose a date")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !model.isToday {
                Button("Today") { model.goToToday() }
            }
            Menu("Day options", systemImage: "ellipsis") {
                Button("Copy whole day from yesterday", systemImage: "doc.on.doc") {
                    model.copy(from: model.day.previous, slotID: nil)
                }
                Button("Copy whole day from date…", systemImage: "calendar") { copyRequest = CopyRequest(slotID: nil) }
                Divider()
                Button(
                    model.diary?.note?.isComplete == true ? "Unmark fully logged" : "Mark day as fully logged",
                    systemImage: "checkmark.seal",
                ) { model.toggleComplete() }
                Button("Edit note", systemImage: "square.and.pencil") { showNoteEditor = true }
            }
        }
    }

    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { value in
            let dx = value.translation.width, dy = value.translation.height
            guard abs(dx) > 80, abs(dx) > abs(dy) * 2 else { return }
            withAnimation(.snappy) {
                if dx < 0 {
                    model.goToNextDay()
                } else {
                    model.goToPreviousDay()
                }
            }
        }
    }
}

// MARK: - Rows & header

struct EntryRow: View {
    let entry: DiaryEntry
    let unit: EnergyUnit
    var isLiquid = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NL.Spacing.m) {
            if entry.isQuickAdd {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Quick add")
            }
            VStack(alignment: .leading, spacing: NL.Spacing.xxs) {
                Text(entry.displayName)
                    .lineLimit(2)
                if entry.isQuickAdd {
                    MacroLine(protein: entry.proteinG, carbs: entry.carbsG, fat: entry.fatG)
                } else {
                    Text(Format.amount(grams: entry.grams, unit: BaseUnit(isLiquid: isLiquid), servingLabel: entry.servingLabel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = entry.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).italic()
                }
            }
            Spacer()
            Text(unit.format(entry.kcal))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DaySummaryHeader: View {
    let totals: Nutrients
    let target: Target?
    let unit: EnergyUnit

    var body: some View {
        HStack(spacing: NL.Spacing.l) {
            EnergyRing(consumed: unit.display(totals.kcal), target: target.map { unit.display($0.kcal) }, unit: unit.symbol)
                .frame(width: 112, height: 112)
            VStack(spacing: NL.Spacing.s) {
                MacroBar(macro: .protein, value: totals.proteinG, target: target?.proteinG)
                MacroBar(macro: .carbs, value: totals.carbsG, target: target?.carbsG)
                MacroBar(macro: .fat, value: totals.fatG, target: target?.fatG)
            }
        }
        if totals.fiberG != nil || totals.sugarG != nil || totals.sodiumMg != nil || totals.caffeineMg != nil {
            HStack(spacing: NL.Spacing.l) {
                minor("Fiber", totals.fiberG, "g", target: target?.fiberG)
                minor("Sugar", totals.sugarG, "g")
                minor("Sodium", totals.sodiumMg, "mg")
                if let caffeine = totals.caffeineMg {
                    minor("Caffeine", caffeine, "mg")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if target == nil {
            Label("Set a calorie target in Settings → Profile & targets", systemImage: "target")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func minor(_ title: String, _ value: Double?, _ unit: String, target: Double? = nil) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Text(value
                .map { NutrientRow.format($0, unit: unit) + (target.map { " / \(NutrientRow.format($0, unit: unit))" } ?? "") + " \(unit)"
                } ?? "—")
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    DiaryView().environment(AppEnvironment.preview(sampleData: true))
}
