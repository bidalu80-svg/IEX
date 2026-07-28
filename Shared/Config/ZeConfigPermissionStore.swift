import Foundation
import Combine

/// Master switch controlling whether the agent can use the
/// `ze-config` CLI at all.
///
/// This is intentionally a separate store from `OffloadPermissionManager`
/// — that one tracks per-command privacy levels (camera, healthkit, …)
/// for shell offloads, while this one is a single boolean gate at the
/// top of the entire ze-config subsystem. Disabling it short-circuits
/// every CLI call before any field lookup, ConfirmationGate enqueue,
/// or audit write.
///
/// The flag itself is intentionally *not* settable through ze-config:
/// the registry registers a hidden placeholder on the same path so any
/// agent attempt to flip the switch (off → silence, on → self-grant)
/// returns `permission_denied`.
@MainActor
final class ZeConfigPermissionStore: ObservableObject {
    static let shared = ZeConfigPermissionStore()

    static let userDefaultsKey = "permissions.zeConfig.enabled"

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.userDefaultsKey)
        }
    }

    private init() {
        // Default: true (preserves existing behaviour for users who
        // upgrade into a build that adds the gate).
        if UserDefaults.standard.object(forKey: Self.userDefaultsKey) == nil {
            self.enabled = true
        } else {
            self.enabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
        }
    }
}
