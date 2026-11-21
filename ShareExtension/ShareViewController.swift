import UIKit

final class ShareViewController: UIViewController {
    private var started = false
    private let progress = UIActivityIndicatorView(style: .large)

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true

        guard let inbox = SharedContainerStore.shareInbox else {
            showResult(title: String(localized: "Could not share to Ze"),
                       message: String(localized: "Shared storage is unavailable. Use Open in Ze from the source app, or save to Files and attach it in Ze."),
                       canOpenZe: false)
            return
        }

        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        progress.startAnimating()
        Task { @MainActor in
            let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            let result = await ShareViewModel().receive(items, in: inbox)
            guard result.saved > 0 else {
                showResult(title: String(localized: "Could not share to Ze"),
                           message: String(localized: "Ze could not save these items. Try Open in Ze or attach them from Files."),
                           canOpenZe: false)
                return
            }
            let message = result.failed == 0
                ? String(localized: "Switch to Ze to add the shared items to a chat.")
                : String(localized: "Some items could not be saved. Switch to Ze to receive the items that were saved.")
            showResult(title: String(localized: "Received by Ze"), message: message, canOpenZe: true)
        }
    }

    private func showResult(title: String, message: String, canOpenZe: Bool) {
        progress.stopAnimating()
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .cancel) { [weak self] _ in
            self?.finish()
        })
        if canOpenZe {
            alert.addAction(UIAlertAction(title: String(localized: "Open Ze"), style: .default) { [weak self] _ in
                self?.openZe()
            })
        }
        present(alert, animated: true)
    }

    private func openZe() {
        guard let context = extensionContext, let url = URL(string: "ze://share") else {
            finish()
            return
        }
        context.open(url) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [])
    }
}
