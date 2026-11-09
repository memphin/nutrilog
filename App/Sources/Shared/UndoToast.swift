import DesignSystem
import SwiftUI
import UIKit

/// A pending "Undo" action shown for 5 seconds — while VoiceOver runs, until used or replaced (backlog #7, #12).
struct UndoAction: Identifiable {
    let id = UUID()
    let message: String
    let undo: @MainActor () -> Void
}

struct UndoToast: View {
    let action: UndoAction
    let onUndo: () -> Void
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: NL.Spacing.m) {
            Text(action.message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: NL.Spacing.s)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                // With VoiceOver the toast doesn't time out; this action closes it without undoing.
                .accessibilityAction(named: "Dismiss", onDismiss)
        }
        .padding(.horizontal, NL.Spacing.l)
        .padding(.vertical, NL.Spacing.m)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, NL.Spacing.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Holds at most one undo action and dismisses it after `duration`. Every offer is announced to VoiceOver,
/// and while VoiceOver runs the action stays until it is used, replaced or dismissed: reaching the Undo
/// button by swiping takes longer than the timeout.
@MainActor
@Observable
final class UndoCenter {
    private(set) var current: UndoAction?
    private var dismissTask: Task<Void, Never>?
    let duration: Duration
    private let isVoiceOverRunning: @MainActor () -> Bool
    private let announce: @MainActor (String) -> Void

    init(
        duration: Duration = .seconds(5),
        isVoiceOverRunning: @escaping @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning },
        announce: @escaping @MainActor (String) -> Void = { UndoCenter.postAnnouncement($0) },
    ) {
        self.duration = duration
        self.isVoiceOverRunning = isVoiceOverRunning
        self.announce = announce
    }

    /// "Deleted Oats. Undo available".
    static func announcement(for message: String) -> String {
        "\(message). Undo available"
    }

    static func postAnnouncement(_ text: String) {
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    func offer(_ message: String, undo: @escaping @MainActor () -> Void) {
        let action = UndoAction(message: message, undo: undo)
        current = action
        dismissTask?.cancel()
        dismissTask = nil
        announce(Self.announcement(for: message))
        guard !isVoiceOverRunning() else { return }
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
                UndoToast(action: action, onUndo: { center.performUndo() }, onDismiss: { center.dismiss() })
                    .padding(.bottom, NL.Spacing.s)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: center.current?.id)
    }
}
