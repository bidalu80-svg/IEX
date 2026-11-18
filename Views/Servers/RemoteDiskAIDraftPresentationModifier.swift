import SwiftUI

/// Separate from the large chat body to keep SwiftUI expression checking small.
struct RemoteDiskAIDraftPresentationModifier: ViewModifier {
    @ObservedObject private var store = RemoteDiskAIDraftStore.shared

    func body(content: Content) -> some View {
        content.sheet(item: Binding<RemoteDiskAIDraft?>(
            get: { store.pending },
            set: { if $0 == nil { store.dismiss() } }
        )) { draft in
            RemoteDiskEditorView(disk: draft.disk)
        }
    }
}
