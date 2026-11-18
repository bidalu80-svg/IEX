import SwiftUI

struct AOJITRestoreButton: View {
    let state: AOJITLibraryState
    let busy: Bool
    let restore: () -> Void
    @State private var confirming = false

    var body: some View {
        Button("Restore bundled build…") { confirming = true }
            .disabled(busy)
            .confirmationDialog("Restore bundled core packages?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Restore", role: .destructive, action: restore)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This replaces installed core packages with the bundled build. The current packages must be downloaded for rollback first. A later apk upgrade may replace the restored build again.")
            }
    }
}
