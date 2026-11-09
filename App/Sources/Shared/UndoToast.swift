import DesignSystem
import SwiftUI

/// A pending "Undo" action shown for 5 seconds (backlog #7, #12).
struct UndoAction: Identifiable {
    let id = UUID()
    let message: String
    let undo: @MainActor () -> Void
}

struct UndoToast: View {
    let action: UndoAction
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: NL.Spacing.m) {
            Text(action.message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: NL.Spacing.s)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, NL.Spacing.l)
        .padding(.vertical, NL.Spacing.m)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, NL.Spacing.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Holds at most one undo action and dismisses it after `duration`.
@MainActor
@Observable
final class UndoCenter {
    private(set) var current: UndoAction?
    private var dismissTask: Task<Void, Never>?
    let duration: Duration

    init(duration: Duration = .seconds(5)) {
        self.duration = duration
    }

    func offer(_ message: String, undo: @escaping @MainActor () -> Void) {
        let action = UndoAction(message: message, undo: undo)
        current = action
        dismissTask?.cancel()
        dismissTask = Task { [weak self, duration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self?.current?.id == action.id else { return }
            self?.current = nil
        }
    }

    func performUndo() {
        guard let action = current else { return }
        current = nil
        dismissTask?.cancel()
        action.undo()
    }

    func dismiss() {
        current = nil
        dismissTask?.cancel()
    }
}

extension View {
    /// Shows the undo toast of `center` at the bottom of the view.
    func undoToast(_ center: UndoCenter) -> some View {
        overlay(alignment: .bottom) {
            if let action = center.current {
                UndoToast(action: action) { center.performUndo() }
                    .padding(.bottom, NL.Spacing.s)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: center.current?.id)
    }
}
