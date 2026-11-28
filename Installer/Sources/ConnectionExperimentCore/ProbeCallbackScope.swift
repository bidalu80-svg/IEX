import Foundation

/// A host lease callback carries the token from registration, including across a
/// subsequent queue/actor hop. Looking up a current callback at delivery is unsafe.
@MainActor public final class ProbeCallbackScope {
    private var token: UUID?
    public init() {}
    @discardableResult public func begin() -> UUID { let value = UUID(); token = value; return value }
    public func invalidate() { token = nil }
    public func isCurrent(_ value: UUID) -> Bool { token == value }
    public func bind(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let captured = token
        return { [weak self] in
            guard let self, let captured, self.token == captured else { return }
            action()
        }
    }
}
