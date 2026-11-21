import Foundation
import UniformTypeIdentifiers

@main struct ShareProviderRegistrationProbe {
    private enum Registration: String, CaseIterable {
        case copyFile, inPlaceFile, data, absent
    }

    private struct RegistrationSnapshot: Equatable {
        let identifiers: [String]
        let allIdentifiers: [String]
        let inPlaceIdentifiers: [String]
        let hasType: Bool
        let hasRepresentation: Bool
        let hasInPlaceRepresentation: Bool

        init(_ provider: NSItemProvider, identifier: String) {
            identifiers = provider.registeredTypeIdentifiers
            allIdentifiers = provider.registeredTypeIdentifiers(fileOptions: [])
            inPlaceIdentifiers = provider.registeredTypeIdentifiers(fileOptions: .openInPlace)
            hasType = provider.hasItemConformingToTypeIdentifier(identifier)
            hasRepresentation = provider.hasRepresentationConforming(toTypeIdentifier: identifier, fileOptions: [])
            hasInPlaceRepresentation = provider.hasRepresentationConforming(toTypeIdentifier: identifier, fileOptions: .openInPlace)
        }
    }

    static func main() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.txt")
        let payload = Data("Registration probe".utf8)
        try payload.write(to: original)

        let utf8 = UTType.utf8PlainText.identifier
        let custom = UTType(exportedAs: "com.ze.share-probe.text", conformingTo: .plainText).identifier
        print("OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        for (identifier, suggestedName) in [(utf8, "README"), (custom, "report.xyz")] {
            var snapshots: [Registration: RegistrationSnapshot] = [:]
            for registration in Registration.allCases {
                for succeeds in registration == .absent ? [false] : [true, false] {
                    let makeProvider = {
                        provider(identifier, suggestedName: suggestedName, registration: registration,
                                 original: original, payload: payload, succeeds: succeeds)
                    }
                    let fileProvider = makeProvider()
                    let snapshot = RegistrationSnapshot(fileProvider, identifier: identifier)
                    snapshots[registration] = snapshot
                    let fileResult = await observeFile(fileProvider, identifier: identifier, original: original, payload: payload)
                    let dataResult = await observeData(makeProvider(), identifier: identifier, payload: payload)
                    print("\(suggestedName) \(registration.rawValue) sourceSucceeds=\(succeeds) \(snapshot)")
                    print("  loadFileRepresentation: \(fileResult)")
                    print("  loadDataRepresentation: \(dataResult)")
                }
            }
            print("\(suggestedName) copyFileVsDataQueriesEqual=\(snapshots[.copyFile] == snapshots[.data])")
        }
    }

    private static func provider(_ identifier: String, suggestedName: String, registration: Registration,
                                 original: URL, payload: Data, succeeds: Bool) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName
        let failure = NSError(domain: "Ze.ShareProviderRegistrationProbe", code: 17)
        switch registration {
        case .copyFile, .inPlaceFile:
            let inPlace = registration == .inPlaceFile
            provider.registerFileRepresentation(forTypeIdentifier: identifier, fileOptions: inPlace ? .openInPlace : [], visibility: .all) { complete in
                complete(succeeds ? original : nil, inPlace, succeeds ? nil : failure)
                return nil
            }
        case .data:
            provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { complete in
                complete(succeeds ? payload : nil, succeeds ? nil : failure)
                return nil
            }
        case .absent:
            break
        }
        return provider
    }

    private static func observeFile(_ provider: NSItemProvider, identifier: String, original: URL, payload: Data) async -> String {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                let contents: Data? = url.flatMap { localURL in
                    guard localURL.isFileURL else { return nil }
                    return try? Data(contentsOf: localURL)
                }
                let originalURL = url?.standardizedFileURL == original.standardizedFileURL
                continuation.resume(returning: "url=\(url != nil) fileURL=\(url?.isFileURL == true) originalURL=\(originalURL) bytesMatch=\(contents == payload) error=\(errorSignature(error))")
            }
        }
    }

    private static func observeData(_ provider: NSItemProvider, identifier: String, payload: Data) async -> String {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                continuation.resume(returning: "data=\(data != nil) bytesMatch=\(data == payload) error=\(errorSignature(error))")
            }
        }
    }

    private static func errorSignature(_ error: Error?) -> String {
        guard let error else { return "none" }
        let reported = error as NSError
        let signature = "\(reported.domain):\(reported.code)"
        guard let underlying = reported.userInfo[NSUnderlyingErrorKey] as? NSError else { return signature }
        return "\(signature) underlying=\(underlying.domain):\(underlying.code)"
    }
}
