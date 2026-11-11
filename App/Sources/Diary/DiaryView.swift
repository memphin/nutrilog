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
    /// Adds to the meal plan instead of logging: nothing counts as eaten until it is confirmed.
    var planned = false
    var id: String {
        "\(day)-\(slotID)\(planned ? "-plan" : "")"
    }

    /// The quick-add form for this target: plans the calories when `planned`, logs them otherwise.
    var quickAddMode: QuickAddView.Mode {
        .create(slotID: slotID, day: day, planned: planned)
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
    @State private var plannedAction: PlannedEntry?
    @State private var editingPlanned: PlannedEntry?
    @State private var movingPlanned: PlannedEntry?
    @State private var repeatRequest: RepeatRequest?
    @State private var showMealPlan = false

    struct CopyRequest: Identifiable {
        let slotID: String?
        var id: String {
            slotID ?? "day"
        }
    }

    /// "Plan for the next days…" of one meal, or of the whole day when `slotID` is nil.
    struct RepeatRequest: Identifiable {
        let slotID: String?
        let title: String
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
                if !model.planned.isEmpty {
                    PlannedSummaryRow(
                        planned: model.plannedTotals, eaten: model.diary?.totals ?? .zero, target: model.target,
                        unit: model.energyUnit, canConfirm: !model.isFuture,
                    ) { model.confirmAll(slotID: nil) }
                }
            }

            if let diary = model.diary {
                // Includes switched-off slots that only hold planned food, so that plan stays visible and editable.
                ForEach(model.sections) { section in
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
                        ForEach(model.planned(in: section.slot.id)) { planned in
                            PlannedRow(
                                entry: planned,
                                unit: model.energyUnit,
                                isLiquid: planned.foodID.map(model.liquidFoodIDs.contains) ?? false,
                                canConfirm: !model.isFuture,
                            ) { model.confirm([planned]) }
                                .contentShape(Rectangle())
                                .onTapGesture { plannedAction = planned }
                                .contextMenu { plannedMenu(planned) }
                                .swipeActions(edge: .trailing) {
                                    Button("Remove", systemImage: "trash", role: .destructive) { model.deletePlanned([planned]) }
                                }
                                .swipeActions(edge: .leading) {
                                    if !model.isFuture {
                                        Button("Eaten", systemImage: "checkmark") { model.confirm([planned]) }
                                            .tint(.green)
                                    }
                                }
                        }
                        Button {
                            addTarget = AddTarget(slotID: section.slot.id, day: model.day, planned: model.isFuture)
                        } label: {
                            Label(model.isFuture ? "Plan food" : "Add food", systemImage: "plus")
                        }
                        .accessibilityLabel("\(model.isFuture ? "Plan food for" : "Add food to") \(section.slot.name)")
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
        .task(id: model.day) { await model.observePlan() }
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
            QuickAddView(mode: target.quickAddMode)
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
        .confirmationDialog(
            plannedAction?.displayName ?? "Planned",
            isPresented: Binding(get: { plannedAction != nil }, set: {
                if !$0 {
                    plannedAction = nil
                }
            }),
            titleVisibility: .visible,
            presenting: plannedAction,
        ) { planned in
            plannedMenu(planned)
        } message: { _ in
            Text(model.isFuture ? "Planned — confirm it on the day you eat it." : "Planned — not counted until you confirm it.")
        }
        .sheet(item: $editingPlanned) { planned in
            EditPlannedView(entry: planned)
        }
        .sheet(item: $movingPlanned) { planned in
            MoveToDateSheet(
                title: "Move \(planned.displayName)", day: planned.day, slotID: planned.mealSlotID, slots: model.moveTargets(for: planned),
            ) { slotID, day in
                model.movePlanned(planned, toSlot: slotID, day: day)
            }
        }
        .sheet(item: $repeatRequest) { request in
            RepeatPlanSheet(title: request.title, from: model.day) { days in
                model.repeatOnNextDays(slotID: request.slotID, days: days)
            }
        }
        .sheet(isPresented: $showMealPlan) {
            MealPlanView { day in
                model.day = day
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

    private func sectionHeader(_ section: DiaryModel.MealSection) -> some View {
        HStack {
            Text(section.slot.name)
            Spacer()
            if !section.entries.isEmpty {
                Text(model.energyUnit.format(section.totals.kcal))
                    .monospacedDigit()
            }
            Menu {
                if model.isFuture {
                    Button("Plan food", systemImage: "plus") {
                        addTarget = AddTarget(slotID: section.slot.id, day: model.day, planned: true)
                    }
                    Button("Plan calories", systemImage: "bolt") {
                        quickAddTarget = AddTarget(slotID: section.slot.id, day: model.day, planned: true)
                    }
                } else {
                    Button("Add food", systemImage: "plus") { addTarget = AddTarget(slotID: section.slot.id, day: model.day) }
                    Button("Quick add calories", systemImage: "bolt") {
                        quickAddTarget = AddTarget(slotID: section.slot.id, day: model.day)
                    }
                    if model.isToday {
                        Button("Plan for later today", systemImage: "calendar.badge.plus") {
                            addTarget = AddTarget(slotID: section.slot.id, day: model.day, planned: true)
                        }
                    }
                }
                if !model.isFuture, !model.planned(in: section.slot.id).isEmpty {
                    Button("Mark planned as eaten", systemImage: "checkmark.circle") { model.confirmAll(slotID: section.slot.id) }
                }
                Button("Plan for the next days…", systemImage: "calendar.badge.clock") {
                    repeatRequest = RepeatRequest(slotID: section.slot.id, title: "Plan \(section.slot.name)")
                }
                .disabled(section.entries.isEmpty && model.planned(in: section.slot.id).isEmpty)
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

    @ViewBuilder
    private func plannedMenu(_ planned: PlannedEntry) -> some View {
        if !model.isFuture {
            Button("Eaten as planned", systemImage: "checkmark.circle") { model.confirm([planned]) }
            if !planned.isQuickAdd {
                Button("Eaten, different amount…", systemImage: "pencil.and.list.clipboard") {
                    editing = model.confirmForEditing(planned)
                }
            }
        }
        if !planned.isQuickAdd {
            Button("Change planned amount…", systemImage: "pencil") { editingPlanned = planned }
        }
        Menu("Move to", systemImage: "arrow.right.square") {
            ForEach(model.slots.filter { $0.id != planned.mealSlotID }) { slot in
                Button(slot.name) { model.movePlanned(planned, toSlot: slot.id) }
            }
            Divider()
            Button("Another day…", systemImage: "calendar") { movingPlanned = planned }
        }
        Button("Remove from plan", systemImage: "trash", role: .destructive) { model.deletePlanned([planned]) }
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
            Button("Meal plan", systemImage: "calendar.badge.clock") { showMealPlan = true }
            Menu("Day options", systemImage: "ellipsis") {
                Button("Copy whole day from yesterday", systemImage: "doc.on.doc") {
                    model.copy(from: model.day.previous, slotID: nil)
                }
                Button("Copy whole day from date…", systemImage: "calendar") { copyRequest = CopyRequest(slotID: nil) }
                Divider()
                if !model.isFuture, !model.planned.isEmpty {
                    Button("Mark all planned as eaten", systemImage: "checkmark.circle") { model.confirmAll(slotID: nil) }
                }
                Button("Plan this day for the next days…", systemImage: "calendar.badge.clock") {
                    repeatRequest = RepeatRequest(slotID: nil, title: "Plan whole day")
                }
                .disabled((model.diary?.entryCount ?? 0) == 0 && model.planned.isEmpty)
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
        if totals.fiberG != nil || totals.sugarG != nil || totals.sodiumMg != nil {
            HStack(spacing: NL.Spacing.l) {
                minor("Fiber", totals.fiberG, "g", target: target?.fiberG)
                minor("Sugar", totals.sugarG, "g")
                minor("Sodium", totals.sodiumMg, "mg")
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
