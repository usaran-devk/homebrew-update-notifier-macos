import Foundation

/// Localization system supporting English and German.
///
/// All user-facing strings are accessed via `L10n` keys.
/// The current locale is determined automatically from the system language.
enum L10n {

    // MARK: - Locale Detection

    /// The current language, derived from system locale.
    private static var isGerman: Bool {
        Locale.current.language.languageCode?.identifier == "de"
    }

    /// Returns the localized string for the current locale.
    /// - Parameters:
    ///   - en: English string.
    ///   - de: German string.
    /// - Returns: The appropriate translation.
    private static func localized(_ en: String, _ de: String) -> String {
        isGerman ? de : en
    }

    // MARK: - App Name
    /// The localized application name.
    static var appName: String { localized("Koebes", "Köbes") }
    static var appNameShortDescription: String { localized("Your Homebrew Update Manager", "Dein Homebrew-Aktualisierungsmanager") }

    // MARK: - State

    /// Strings describing the current update state.
    enum State {
        static var upToDate: String { localized("All packages up to date", "Alle Pakete aktuell") }
        static var updatesAvailable: String { localized("Updates available", "Updates verfügbar") }
        static var checking: String { localized("Checking for updates…", "Suche nach Updates…") }
        static var checkError: String { localized("Check for updates failed", "Prüfung auf Updates fehlgeschlagen") }
        static var updating: String { localized("Updating packages…", "Pakete werden aktualisiert…") }
        static var updateComplete: String { localized("Update finished", "Aktualisierung abgeschlossen") }
        static var updateCompletedWithErrors: String { localized("Update finished with errors", "Aktualisierung mit Fehlern abgeschlossen") }
        static var error: String { localized("Error checking for updates", "Fehler bei der Update-Prüfung") }
        static var unknown: String { localized("Unknown state", "Unbekannter Zustand") }
    }

    // MARK: - Menu

    /// Menu item strings.
    enum Menu {
        static var selectAll: String { localized("Select All", "Alle auswählen") }
        static var deselectAll: String { localized("Deselect All", "Alle abwählen") }
        static var updateSelected: String { localized("Update Selected", "Ausgewählte aktualisieren") }
        static var updateSelectedWithForce: String { localized("Update Selected with --force", "Ausgewählte mit --force erneut installieren") }
        static var updateModePromptTitle: String { localized("Choose update mode", "Update-Modus wählen") }
        static var updateModePromptMessage: String { localized("Install selected packages normally or force a reinstall with --force.", "Installiere die ausgewählten Pakete normal oder erzwinge eine Neuinstallation mit --force.") }
        static var showRemaining: String { localized("Show Remaining", "Verbleibende anzeigen") }
        static var checkNow: String { localized("Check Now", "Jetzt prüfen") }
        static var settings: String { localized("Settings…", "Einstellungen…") }
        static var quit: String { localized("Quit", "Beenden") }
        static var noUpdates: String { localized("No updates available.", "Keine Updates verfügbar.") }
        static var dependencyTree: String { localized("Dependency Tree", "Abhängigkeitsbaum") }
        static func dependencyTreeForType(_ typeLabel: String) -> String {
            localized("\(dependencyTree): \(typeLabel)", "\(dependencyTree): \(typeLabel)")
        }
        static func dependencyCycleWarning(_ packages: String) -> String {
            localized(
                "Dependency cycle detected: \(packages). Order is best-effort.",
                "Abhängigkeitszyklus erkannt: \(packages). Reihenfolge ist bestmöglich."
            )
        }

        /// Returns a localized display name for a given brew package type.
        /// - Parameter type: The raw type string (e.g. `Constants.PackageType.formula`).
        /// - Returns: A human-readable, localized group label.
        static func packageTypeName(_ type: String) -> String {
            switch type {
            case Constants.PackageType.formula:
                return localized("Formulae (CLI Tools & Libraries)", "Formeln (CLI-Tools & Bibliotheken)")
            case Constants.PackageType.cask:
                return localized("Casks (Apps, Fonts & Drivers)", "Casks (Apps, Schriften & Treiber)")
            default:
                return type.capitalized
            }
        }
    }

    // MARK: - Settings

    /// Settings dialog strings.
    enum Settings {
        static var title: String { localized("Settings", "Einstellungen") }
        static var sectionUpdates: String { localized("Updates", "Updates") }
        static var sectionGeneral: String { localized("General", "Allgemein") }
        static var checkInterval: String { localized("Check interval (minutes)", "Prüfintervall (Minuten)") }
        static var checkIntervalHint: String { localized("Min: \(Constants.Defaults.minCheckIntervalMinutes), Max: \(Constants.Defaults.maxCheckIntervalMinutes)", "Min: \(Constants.Defaults.minCheckIntervalMinutes), Max: \(Constants.Defaults.maxCheckIntervalMinutes)") }
        static var autostart: String { localized("Start at login", "Bei Anmeldung starten") }
        static var greedy: String { localized("Include auto-updating casks (greedy)", "Selbstaktualisierende Casks einbeziehen (greedy)") }
        static var savedPassword: String { localized("Use saved sudo password from Keychain", "Gespeichertes sudo-Passwort aus dem Schlüsselbund verwenden") }
        static var savedPasswordHint: String { localized("Stores your sudo password in the macOS Keychain so updates that require admin rights run without prompting.", "Speichert dein sudo-Passwort im macOS-Schlüsselbund, damit Updates mit Adminrechten ohne Abfrage ausgeführt werden.") }
        static var savedPasswordSet: String { localized("Password is stored in the Keychain.", "Passwort ist im Schlüsselbund gespeichert.") }
        static var savedPasswordNotSet: String { localized("No password stored.", "Kein Passwort gespeichert.") }
        static var savePasswordButton: String { localized("Save Password…", "Passwort speichern…") }
        static var savePasswordVerifyButton: String { localized("Verify and Save", "Prüfen und speichern") }
        static var forgetPasswordButton: String { localized("Forget Password", "Passwort entfernen") }
        static var passwordPromptTitle: String { localized("Save sudo password", "sudo-Passwort speichern") }
        static var passwordPromptMessage: String { localized("Enter your macOS account password. It will be stored encrypted in the Keychain.", "Gib dein macOS-Passwort ein. Es wird verschlüsselt im Schlüsselbund gespeichert.") }
        static var passwordSaveError: String { localized("Failed to save password to Keychain.", "Passwort konnte nicht im Schlüsselbund gespeichert werden.") }
        static var passwordIncorrect: String { localized("Password is incorrect. Nothing was saved.", "Passwort ist falsch. Es wurde nichts gespeichert.") }
        static var passwordVerifyUnavailable: String { localized("Could not verify password — saving anyway.", "Passwort konnte nicht überprüft werden – wird trotzdem gespeichert.") }
        static var save: String { localized("Save", "Speichern") }
        static var cancel: String { localized("Cancel", "Abbrechen") }
        static var sectionPermissions: String { localized("Permissions", "Berechtigungen") }
        static var appManagementHint: String { localized(
            "macOS requires App Management permission to update app bundles (casks such as Firefox, Docker, etc.). Click the button below, find Koebes in the list, and enable the toggle.",
            "macOS benötigt die Berechtigung \"App-Verwaltung\", um App-Pakete (Casks wie Firefox, Docker usw.) zu aktualisieren. Klicke auf den Button, suche Köbes in der Liste und aktiviere den Schalter."
        ) }
        static var openAppManagementSettings: String { localized("Open App Management Settings…", "App-Verwaltung öffnen…") }
    }

    // MARK: - Error

    /// Error message strings.
    enum Error {
        static var brewNotFound: String { localized("Homebrew not found", "Homebrew nicht gefunden") }
        static var savedPasswordInvalid: String { localized("Saved sudo password is no longer valid. Please save it again.", "Gespeichertes sudo-Passwort ist nicht mehr gültig. Bitte erneut speichern.") }
        static var savedPasswordUnavailable: String { localized("Could not verify saved sudo password. Please save it again.", "Gespeichertes sudo-Passwort konnte nicht überprüft werden. Bitte erneut speichern.") }
    }

    // MARK: - Log

    /// Log output strings.
    enum Log {
        static var checkDetails: String { localized("Details", "Details") }
        static var lastChecked: String { localized("Last checked: ", "Zuletzt geprüft: ") }
    }

    // MARK: - Package Status

    /// Per-package update status strings.
    enum PackageStatus {
        static var queued: String { localized("Queued", "Wartend") }
        static var updating: String { localized("Updating…", "Wird aktualisiert…") }
        static var success: String { localized("Updated", "Aktualisiert") }
        static var failed: String { localized("Failed", "Fehlgeschlagen") }
    }
}
