import SwiftUI

extension View {
    /// An alert titled `title` that shows `message` with an OK button while it is non-nil; dismissing it sets
    /// `message` back to nil.
    func errorAlert(_ message: Binding<String?>, title: LocalizedStringKey = "Error") -> some View {
        alert(title, isPresented: Binding(get: { message.wrappedValue != nil }, set: {
            if !$0 {
                message.wrappedValue = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
