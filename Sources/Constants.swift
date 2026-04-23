import Foundation

/// Centralized constants for the Homebrew Update Notifier application.
enum Constants {

    /// Application name.
    static let appName = "Homebrew Update Notifier"

    // MARK: - Executables

    /// Paths to external executables.
    enum Executables {
        /// Path to homebrew on Apple Silicon Macs.
        static let brewARM = "/opt/homebrew/bin/brew"
        /// Path to homebrew on Intel Macs.
        static let brewIntel = "/usr/local/bin/brew"
    }

    // MARK: - Process

    /// Process-related constants.
    enum Process {
        /// Arguments for fetching latest formula/cask definitions.
        static let updateArgs = ["update"]
        /// Arguments for checking outdated packages.
        static let outdatedArgs = ["outdated", "--json=v2"]
        /// Arguments for checking outdated packages (plain text for log output).
        static let outdatedPlainArgs = ["outdated", "--verbose"]
        /// Arguments for upgrading specific packages.
        static let upgradeArgs = ["upgrade"]
        /// Filename for the temporary SUDO_ASKPASS helper script (interactive mode).
        static let askpassFilename = "homebrew-update-notifier-askpass.sh"
        /// Filename for the temporary SUDO_ASKPASS helper script (keychain mode).
        static let askpassKeychainFilename = "homebrew-update-notifier-askpass-keychain.sh"
    }

    // MARK: - Keychain

    /// Keychain-related constants.
    enum Keychain {
        /// Service name used for the generic password item that stores the
        /// user's sudo password in the macOS Keychain.
        static let serviceName = "de.devk.homebrew-update-notifier.sudo"
    }

    // MARK: - Defaults

    /// Default values for settings.
    enum Defaults {
        /// Default check interval in minutes.
        static let checkIntervalMinutes: Int = 60
        /// Minimum check interval in minutes.
        static let minCheckIntervalMinutes: Int = 5
        /// Maximum check interval in minutes.
        static let maxCheckIntervalMinutes: Int = 1440
    }

    // MARK: - StorageKeys

    /// UserDefaults keys.
    enum StorageKeys {
        /// Key for storing the check interval.
        static let checkInterval = "checkIntervalMinutes"
        /// Key for storing the autostart preference.
        static let autostart = "autostartEnabled"
        /// Key for storing the greedy upgrade preference.
        static let greedy = "greedyEnabled"
        /// Key for storing whether the sudo password is read from the Keychain.
        static let savedPasswordEnabled = "savedPasswordEnabled"
    }

    // MARK: - UI

    /// UI-related constants.
    enum UI {
        /// Width of the popover/menu.
        static let popoverWidth: CGFloat = 400
        /// Height of the popover/menu.
        static let popoverHeight: CGFloat = 380
        /// Padding for content.
        static let contentPadding: CGFloat = 12
        /// Width of the settings window.
        static let settingsWidth: CGFloat = 560
        /// Height of the settings window.
        static let settingsHeight: CGFloat = 420
        /// Interval between icon animation frames in seconds.
        static let animationInterval: TimeInterval = 0.15
        /// Rotation step per animation frame in degrees.
        static let animationStep: CGFloat = 45
    }

    // MARK: - PackageType

    /// Internal package type identifiers assigned during parsing of `brew outdated --json=v2` output.
    ///
    /// Packages found under the `"formulae"` key are tagged `.formula`;
    /// packages found under the `"casks"` key are tagged `.cask`.
    enum PackageType {
        /// A standard homebrew formula (source-compiled or pre-built binary).
        static let formula = "formula"
        /// A homebrew cask (pre-built binary, app bundle, font, driver, etc.).
        static let cask = "cask"
    }

    // MARK: - Symbols

    /// SF Symbols used in the menu bar and UI.
    enum Symbols {
        /// Base menu bar icon (mug).
        static let base = "mug.fill"
        /// Badge overlay when up to date.
        static let badgeUpToDate = "checkmark.circle.fill"
        /// Badge overlay when updates are available.
        static let badgeUpdatesAvailable = "exclamationmark.circle.fill"
        /// Badge overlay while checking.
        static let badgeChecking = "arrow.triangle.2.circlepath.circle.fill"
        /// Badge overlay on error.
        static let badgeError = "xmark.circle.fill"
        /// Badge overlay when updating.
        static let badgeUpdating = "tray.and.arrow.down.fill"
        /// Per-package: queued (waiting to be updated).
        static let packageQueued = "clock.fill"
        /// Per-package: currently updating.
        static let packageUpdating = "arrow.triangle.2.circlepath"
        /// Per-package: update succeeded.
        static let packageSuccess = "checkmark.circle.fill"
        /// Per-package: update failed.
        static let packageFailed = "xmark.circle.fill"
    }

    // MARK: - Mock Data

    /// Mock data used when compiled with `-DDEBUG_MOCK` for UI testing.
    enum MockData {
        /// Simulated outdated packages.
        static let packages: [BrewPackage] = [
            BrewPackage(type: PackageType.formula, name: "wget", installedVersion: "1.21.3", availableVersion: "1.24.5"),
            BrewPackage(type: PackageType.formula, name: "git", installedVersion: "2.43.0", availableVersion: "2.45.1"),
            BrewPackage(type: PackageType.cask, name: "firefox", installedVersion: "130.0", availableVersion: "131.0.2"),
            BrewPackage(type: PackageType.formula, name: "node", installedVersion: "20.11.0", availableVersion: "22.2.0"),
            BrewPackage(type: PackageType.formula, name: "python@3.12", installedVersion: "3.12.2", availableVersion: "3.12.4"),
            BrewPackage(type: PackageType.cask, name: "docker-desktop", installedVersion: "4.30.0", availableVersion: "4.31.1"),
        ]
        /// Name of the package that simulates a failed upgrade.
        static let failedPackageName = "firefox"
        /// Name of the package that simulates needing sudo (cask install).
        /// In mock mode this triggers the saved-password askpass + `sudo -A -n -v`
        /// validation when `Settings.savedPasswordEnabled` is `true`.
        static let sudoPackageName = "docker-desktop"
        /// Simulated output from `brew update`.
        static let brewUpdateOutput = "Updated 2 taps (homebrew/core and homebrew/cask).\n==> New Formulae\nnewpkg\n==> Updated Formulae\nwget, git, node, python@3.12\n==> Updated Casks\nfirefox, docker-desktop"
        /// Simulated output from `brew outdated --verbose`.
        static let brewOutdatedOutput = "wget (1.21.3) < 1.24.5\ngit (2.43.0) < 2.45.1\nfirefox (130.0) != 131.0.2\nnode (20.11.0) < 22.2.0\npython@3.12 (3.12.2) < 3.12.4\ndocker-desktop (4.30.0) != 4.31.1"
    }

    // MARK: - LaunchAgent

    /// Launch agent constants for autostart.
    enum LaunchAgent {
        /// Bundle identifier used for the launch agent plist.
        static let identifier = "de.devk.homebrew-update-notifier"
        /// Launch agent plist filename.
        static let plistName = "de.devk.homebrew-update-notifier.plist"
    }
}
