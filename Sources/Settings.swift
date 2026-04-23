import Foundation
import ServiceManagement

/// Manages application settings persisted via UserDefaults.
final class Settings: @unchecked Sendable {

    /// Shared singleton instance.
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    // MARK: - Check Interval

    /// The update check interval in minutes.
    var checkIntervalMinutes: Int {
        get {
            let stored = defaults.integer(forKey: Constants.StorageKeys.checkInterval)
            if stored < Constants.Defaults.minCheckIntervalMinutes {
                return Constants.Defaults.checkIntervalMinutes
            }
            return min(stored, Constants.Defaults.maxCheckIntervalMinutes)
        }
        set {
            let clamped = max(
                Constants.Defaults.minCheckIntervalMinutes,
                min(newValue, Constants.Defaults.maxCheckIntervalMinutes)
            )
            defaults.set(clamped, forKey: Constants.StorageKeys.checkInterval)
        }
    }

    /// The check interval as a `TimeInterval` in seconds.
    var checkIntervalSeconds: TimeInterval {
        TimeInterval(checkIntervalMinutes * 60)
    }

    // MARK: - Autostart

    /// Whether the app should start at login.
    var autostartEnabled: Bool {
        get {
            defaults.bool(forKey: Constants.StorageKeys.autostart)
        }
        set {
            defaults.set(newValue, forKey: Constants.StorageKeys.autostart)
            updateLoginItem(enabled: newValue)
        }
    }

    // MARK: - Greedy

    /// Whether to use the `--greedy` flag when checking and upgrading.
    ///
    /// When enabled, casks that set their version to `latest` or auto-update
    /// themselves are also included in the outdated/upgrade list.
    /// Defaults to `true`.
    var greedyEnabled: Bool {
        get {
            // Default to true if never set
            if defaults.object(forKey: Constants.StorageKeys.greedy) == nil {
                return true
            }
            return defaults.bool(forKey: Constants.StorageKeys.greedy)
        }
        set {
            defaults.set(newValue, forKey: Constants.StorageKeys.greedy)
        }
    }

    // MARK: - Saved Password

    /// Whether the sudo password should be retrieved from the macOS Keychain
    /// during `brew upgrade`, instead of prompting the user interactively.
    ///
    /// When enabled, `BrewManager.makeUpgradeEnvironment()` writes a small
    /// askpass helper that reads the password via `KeychainHelper`. The
    /// password itself is stored separately in the Keychain — toggling this
    /// flag does not save or remove the password.
    /// Defaults to `false` (interactive prompt).
    var savedPasswordEnabled: Bool {
        get {
            defaults.bool(forKey: Constants.StorageKeys.savedPasswordEnabled)
        }
        set {
            defaults.set(newValue, forKey: Constants.StorageKeys.savedPasswordEnabled)
        }
    }

    // MARK: - Private

    private init() {}

    /// Registers/unregisters the app as a login item using SMAppService.
    /// - Parameter enabled: Whether to enable or disable the login item.
    private func updateLoginItem(enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                NSLog("Failed to update login item: \(error)")
            }
        }
    }
}
