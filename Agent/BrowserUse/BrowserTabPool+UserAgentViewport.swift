import Foundation
import Combine

private let logger = AppLogger(category: "BrowserTabPool")

extension BrowserTabPool {
    /// Whether a custom viewport (global or session) is currently active.
    func hasCustomViewport() -> Bool {
        return (sessionViewportWidth > 0 && sessionViewportHeight > 0)
            || (customViewportWidth > 0 && customViewportHeight > 0)
    }
}
