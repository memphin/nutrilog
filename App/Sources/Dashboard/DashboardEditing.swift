import DesignSystem
import SwiftUI

// MARK: - Editing the layout on Today

/// Long-press a tile to start editing — the same press lifts the tile, so it can be dragged straight away without
/// pressing it again. While editing, a tile no longer opens its detail or takes quick-adds: it can be dragged onto
/// another tile's place, or hidden with its badge. VoiceOver gets Move up / Move down / Hide actions.
struct EditableTile: ViewModifier {
    let tile: DashboardTile
    let model: DashboardModel
    @Binding var dragging: DashboardTile?

    func body(content: Content) -> some View {
        // The drag and drop stay outside the editing switch: the long press that starts editing is also the start of
        // the drag, and that drag has to survive the tile changing into its editing look.
        editingLook(content)
            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: NL.Radius.m))
            .onDrag {
                if !model.isEditing {
                    withAnimation(.snappy) { model.isEditing = true }
                }
                TileDropDelegate.lifted = tile
                return NSItemProvider(object: tile.rawValue as NSString)
            }
            .onDrop(of: [.text], delegate: TileDropDelegate(target: tile, model: model, dragging: $dragging))
            .modifier(EndsDragOnSessionEnd(dragging: $dragging))
    }

    @ViewBuilder private func editingLook(_ content: Content) -> some View {
        if model.isEditing {
            content
                .allowsHitTesting(false)
                .overlay {
                    RoundedRectangle(cornerRadius: NL.Radius.m)
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                }
                .overlay(alignment: .topLeading) {
                    Button {
                        withAnimation(.snappy) { model.hideTile(tile) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -NL.Spacing.s, y: -NL.Spacing.s)
                    .accessibilityHidden(true) // the Hide action below
                }
                .contentShape(RoundedRectangle(cornerRadius: NL.Radius.m))
                .scaleEffect(0.97)
                .opacity(dragging == tile ? 0.4 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tile.title)
                .accessibilityHint("Editing Today. Use the actions to move or hide this tile.")
                .accessibilityAction(named: "Move up") { model.moveTile(tile, by: -1) }
                .accessibilityAction(named: "Move down") { model.moveTile(tile, by: 1) }
                .accessibilityAction(named: "Hide") { model.hideTile(tile) }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            content
                .accessibilityAction(named: "Edit Today") { model.isEditing = true }
        }
    }
}

/// iOS 27 reports when a drag ends however it ends (dropped, let go in place, cancelled), so the dragged tile never
/// stays dimmed. Earlier systems rely on the drop delegates alone.
private struct EndsDragOnSessionEnd: ViewModifier {
    @Binding var dragging: DashboardTile?

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.onDragSessionUpdated { session in
                if case .ended = session.phase {
                    dragging = nil
                    TileDropDelegate.lifted = nil
                }
            }
        } else {
            content
        }
    }
}

/// While dragging, the dragged tile takes the place of the tile under the finger. Moves are spaced out so the rows
/// re-flowing under the finger (wide and narrow tiles) don't bounce a tile back and forth.
private struct TileDropDelegate: DropDelegate {
    let target: DashboardTile
    let model: DashboardModel
    @Binding var dragging: DashboardTile?

    /// The tile lifted by the last long press. It becomes `dragging` (and dims) only once the finger moves: a long
    /// press let go in place has no drop to end it, and would leave the tile dimmed.
    @MainActor static var lifted: DashboardTile?
    @MainActor private static var lastMove = Date.distantPast

    func dropEntered(info _: DropInfo) {
        if dragging == nil {
            dragging = Self.lifted
        }
        guard let dragging, dragging != target, Date.now.timeIntervalSince(Self.lastMove) > 0.3 else { return }
        Self.lastMove = .now
        withAnimation(.snappy) { model.moveTile(dragging, onto: target) }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        if dragging == nil {
            dragging = Self.lifted
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragging = nil
        Self.lifted = nil
        return true
    }
}

struct EndDragDelegate: DropDelegate {
    @Binding var dragging: DashboardTile?

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        dragging = nil
        TileDropDelegate.lifted = nil
        return true
    }
}

/// While editing: the hidden tiles, each with a + to show it again (as the last visible tile).
struct HiddenTilesSection: View {
    let model: DashboardModel

    var body: some View {
        let hidden = model.layout.order.filter { !model.layout.isVisible($0) }
        if !hidden.isEmpty {
            VStack(alignment: .leading, spacing: NL.Spacing.s) {
                Text("Hidden")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, NL.Spacing.m)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(hidden) { tile in
                        Button {
                            withAnimation(.snappy) { model.showTile(tile) }
                        } label: {
                            HStack(spacing: NL.Spacing.m) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                                    .imageScale(.large)
                                Label(tile.title, systemImage: tile.systemImage)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(NL.Spacing.m)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(tile.title)")
                        if tile != hidden.last {
                            Divider().padding(.leading, NL.Spacing.m)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: NL.Radius.m))
            }
            .padding(.top, NL.Spacing.l)
            .transition(.opacity)
        }
    }
}
