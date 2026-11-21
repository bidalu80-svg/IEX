import Foundation
import UIKit

@MainActor
enum ShareFeedbackToast {
    static func show(_ message: String, duration: TimeInterval = 3.0) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return }

        let label = UILabel()
        label.text = message
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center

        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        container.layer.cornerRadius = 12
        container.alpha = 0
        container.addSubview(label)
        window.addSubview(container)

        label.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            container.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            container.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, constant: -48),
        ])

        UIView.animate(withDuration: 0.25) { container.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            UIView.animate(withDuration: 0.25, animations: { container.alpha = 0 }) { _ in
                container.removeFromSuperview()
            }
        }
    }
}

@MainActor
final class ShareCoordinator: ObservableObject {
    static let shared = ShareCoordinator()

    @Published private(set) var pending: [PendingShareInbox.Receipt] = []
    @Published private(set) var documentImportsInFlight = 0
    private var awaitingRemoval: [UUID: PendingShareInbox.Receipt] = [:]
    private var showImportFailure = false

    var hasIncomingShares: Bool { !pending.isEmpty || documentImportsInFlight > 0 }

    func documentImportStarted() {
        documentImportsInFlight += 1
    }

    func documentImportFinished() {
        documentImportsInFlight -= 1
        checkForPendingShare()
    }

    func noteDocumentImportFailure() {
        showImportFailure = true
    }

    func checkForPendingShare() {
        if showImportFailure, !SessionLockStore.shared.appIsLocked, UIApplication.shared.applicationState == .active {
            showImportFailure = false
            ShareFeedbackToast.show(String(localized: "Could not receive the shared file. Please try again."))
        }
        for receipt in Array(awaitingRemoval.values) {
            removeAfterDelivery(receipt)
        }
        let local = ExternalFileImporter.inbox.receipts()
        let shared = SharedContainerStore.shareInbox?.receipts() ?? []
        var seen = Set(awaitingRemoval.keys)
        let receipts = (local + shared).filter { seen.insert($0.id).inserted }.sorted {
            if $0.share.receivedAt == $1.share.receivedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.share.receivedAt < $1.share.receivedAt
        }
        if pending != receipts { pending = receipts }
    }

    func acknowledge(_ receipt: PendingShareInbox.Receipt) {
        guard pending.contains(receipt) else { return }
        removeAfterDelivery(receipt)
        pending.removeAll { $0.id == receipt.id }
    }

    private func removeAfterDelivery(_ receipt: PendingShareInbox.Receipt) {
        do {
            try receipt.remove()
            awaitingRemoval[receipt.id] = nil
        } catch {
            if (error as NSError).code == NSFileNoSuchFileError {
                awaitingRemoval[receipt.id] = nil
            } else {
                awaitingRemoval[receipt.id] = receipt
            }
        }
    }
}
