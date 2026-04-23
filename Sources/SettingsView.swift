import AppKit
import SwiftUI

/// Settings window for configuring the update check interval and autostart.
@MainActor
struct SettingsView: View {
    @State private var intervalMinutes: String
    @State private var autostartEnabled: Bool
    @State private var greedyEnabled: Bool
    @State private var savedPasswordEnabled: Bool
    @State private var hasStoredPassword: Bool
    @State private var passwordError: String?
    @State private var passwordErrorDetails: String?

    /// Callback invoked when settings are saved, passing the new interval.
    let onSave: (Int) -> Void

    /// Callback to close the window (since @Environment dismiss doesn't work in NSWindow).
    let onClose: () -> Void

    init(onSave: @escaping (Int) -> Void, onClose: @escaping () -> Void) {
        let settings = Settings.shared
        _intervalMinutes = State(initialValue: String(settings.checkIntervalMinutes))
        _autostartEnabled = State(initialValue: settings.autostartEnabled)
        _greedyEnabled = State(initialValue: settings.greedyEnabled)
        _savedPasswordEnabled = State(initialValue: settings.savedPasswordEnabled)
        _hasStoredPassword = State(initialValue: KeychainHelper.hasStoredPassword())
        _passwordError = State(initialValue: nil)
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField(L10n.Settings.checkInterval, text: $intervalMinutes)
                        .textFieldStyle(.roundedBorder)
                    Text(L10n.Settings.checkIntervalHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Toggle(L10n.Settings.greedy, isOn: $greedyEnabled)
                } header: {
                    Text(L10n.Settings.sectionUpdates)
                }

                Section {
                    Toggle(L10n.Settings.autostart, isOn: $autostartEnabled)

                    Toggle(L10n.Settings.savedPassword, isOn: $savedPasswordEnabled)
                    Text(L10n.Settings.savedPasswordHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        Text(hasStoredPassword
                             ? L10n.Settings.savedPasswordSet
                             : L10n.Settings.savedPasswordNotSet)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(L10n.Settings.savePasswordButton) {
                            promptAndSavePassword()
                        }
                        .buttonStyle(.bordered)
                        Button(L10n.Settings.forgetPasswordButton) {
                            forgetPassword()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasStoredPassword)
                    }
                    if let passwordError {
                        Text(passwordError)
                            .bold()
                            .font(.caption)
                            .foregroundColor(.red)

                        if  let passwordErrorDetails {
                            Text(passwordErrorDetails)
                                .italic()
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text(L10n.Settings.sectionGeneral)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(L10n.Settings.cancel) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.Settings.save) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: Constants.UI.settingsWidth, height: Constants.UI.settingsHeight)
    }

    // MARK: - Private

    private func save() {
        let minutes = Int(intervalMinutes) ?? Constants.Defaults.checkIntervalMinutes
        Settings.shared.checkIntervalMinutes = minutes
        Settings.shared.autostartEnabled = autostartEnabled
        Settings.shared.greedyEnabled = greedyEnabled
        Settings.shared.savedPasswordEnabled = savedPasswordEnabled
        onSave(minutes)
        onClose()
    }

    /// Shows a modal dialog with a secure text field, then writes the entered
    /// password to the Keychain. Errors are surfaced inline.
    private func promptAndSavePassword() {
        passwordError = nil
        passwordErrorDetails = nil

        let alert = NSAlert()
        alert.messageText = L10n.Settings.passwordPromptTitle
        alert.informativeText = L10n.Settings.passwordPromptMessage
        // Use distinct titles to avoid confusion with the outer Settings Save
        // button. The first button is the default action (Return key).
        alert.addButton(withTitle: L10n.Settings.savePasswordVerifyButton)
        alert.addButton(withTitle: L10n.Settings.cancel)

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        // Ensure the secure field is the first responder when the alert opens.
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        let password = field.stringValue
        guard !password.isEmpty else {
            return
        }

        // Verify against PAM/sudo before persisting. On Touch-ID-for-sudo
        // systems this may show a system biometric prompt.
        let result = KeychainHelper.verifyPassword(password)
        switch result {
        case .verified:
            break
        case .incorrect(let details):
            passwordError = L10n.Settings.passwordIncorrect
            passwordErrorDetails = details
            return
        case .unavailable(let reason):
            passwordError = L10n.Settings.passwordVerifyUnavailable + " (\(reason))"
        }

        do {
            try KeychainHelper.save(password: password)
            hasStoredPassword = true
        } catch {
            passwordError = L10n.Settings.passwordSaveError
        }
    }

    /// Removes the stored password from the Keychain.
    private func forgetPassword() {
        passwordError = nil
        do {
            try KeychainHelper.deletePassword()
            hasStoredPassword = false
        } catch {
            passwordError = L10n.Settings.passwordSaveError
        }
    }
}
