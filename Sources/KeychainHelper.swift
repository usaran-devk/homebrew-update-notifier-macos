import Foundation
import Security

/// Errors thrown by `KeychainHelper`.
enum KeychainError: Error {
    /// The password could not be encoded to UTF-8 data.
    case encodingFailed
    /// A Keychain Services API call failed with the given OSStatus.
    case unhandled(OSStatus)
}

/// Thin wrapper around the macOS Keychain Services for storing the user's
/// sudo password as a generic password item.
///
/// The item is stored in the user's default keychain under the service name
/// `Constants.Keychain.serviceName` and account name equal to the current
/// macOS user (`NSUserName()`). The data is encrypted by macOS and protected
/// by the keychain's ACL — only this app (and processes the user explicitly
/// allows) can read it. Reading may trigger a system "allow access?" prompt
/// the first time after a code change.
///
/// This is the recommended secure storage for an "askpass" style helper that
/// needs to provide a sudo password without prompting the user every time.
enum KeychainHelper {

    /// Saves (or overwrites) the password for the current user.
    /// - Parameter password: The clear-text sudo password to store.
    /// - Throws: `KeychainError` if the underlying API fails.
    static func save(password: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // First try to update an existing item.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.serviceName,
            kSecAttrAccount as String: NSUserName(),
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            // Re-prime access in case the item was re-saved (ACL may be reset).
            primeKeychainAccess()
            return
        }

        if updateStatus == errSecItemNotFound {
            // Add a new item. Use kSecAttrAccessibleWhenUnlocked so the value
            // can be read while the user is logged in (required for askpass).
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.unhandled(addStatus)
            }
            // Trigger the "Allow access?" dialog for the `security` CLI now
            // so the user can grant permanent access before any upgrade runs.
            primeKeychainAccess()
            return
        }

        throw KeychainError.unhandled(updateStatus)
    }

    /// Loads the stored password for the current user, if present.
    /// - Returns: The password, or `nil` if no item is stored.
    /// - Throws: `KeychainError` if the underlying API fails for any reason
    ///   other than "item not found".
    static func loadPassword() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.serviceName,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess {
            throw KeychainError.unhandled(status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    /// Removes the stored password for the current user, if present.
    /// - Throws: `KeychainError` if deletion fails for a reason other than
    ///   "item not found".
    static func deletePassword() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.serviceName,
            kSecAttrAccount as String: NSUserName(),
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandled(status)
        }
    }

    /// Returns `true` if a password is currently stored for the current user.
    static func hasStoredPassword() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.serviceName,
            kSecAttrAccount as String: NSUserName(),
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Access Priming

    /// Triggers the macOS "Allow access?" keychain dialog for the `security`
    /// CLI tool by performing a read using that same tool immediately after
    /// the item is saved.
    ///
    /// The `security find-generic-password` command used by the askpass helper
    /// at upgrade time runs as a separate process and is therefore treated by
    /// macOS as a different accessor than this app. The first time it reads the
    /// keychain item it shows a permission dialog. By proactively calling this
    /// method right after saving, the user sees that dialog while still in the
    /// Settings view — where they can conveniently choose "Always Allow" — so
    /// the dialog never interrupts an actual upgrade.
    ///
    /// The return value of `security` is intentionally ignored; the sole
    /// purpose of the call is to register `security` as an allowed accessor.
    @discardableResult
    static func primeKeychainAccess() -> Bool {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-w",
            "-s", Constants.Keychain.serviceName,
            "-a", NSUserName(),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Verification

    /// Result of attempting to verify a candidate sudo password.
    enum VerificationResult: Equatable {
        /// `sudo` accepted the password.
        case verified
        /// `sudo` rejected the password. `details` contains the trimmed first
        /// line of sudo's stderr (e.g. "Sorry, try again." or
        /// "a password is required"); useful for diagnosing why verification
        /// failed without exposing the password itself.
        case incorrect(details: String)
        /// Verification could not be performed (sudo missing, askpass write failed, etc.).
        case unavailable(reason: String)
    }

    /// Verifies a candidate sudo password by invoking
    /// `sudo -S -k -v` with the new password piped via stdin
    ///
    /// - `-S` instructs sudo to read the password from stdin
    /// - `-k` is passed to invalidate any cached sudo timestamp first, so
    ///   verification cannot be silently skipped by an existing session.
    /// - The candidate password is never logged.
    ///
    /// - Parameter password: The candidate password to verify.
    /// - Returns: A `VerificationResult` describing the outcome.
    static func verifyPassword(_ password: String) -> VerificationResult {
        let sudoPath = "/usr/bin/sudo"
        guard FileManager.default.isExecutableFile(atPath: sudoPath) else {
            return .unavailable(reason: "sudo not found at \(sudoPath)")
        }

        // -S tells sudo to read the password via stdin. Do NOT add -n:
        // -n makes sudo refuse to invoke askpass and exit with
        // "a password is required" before our helper is ever called.
        let args = ["-S", "-k", "-v"]

        let process = Foundation.Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: sudoPath)
        process.arguments = args
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .unavailable(reason: "Failed to launch sudo: \(error.localizedDescription)")
        }
        
        // Write password to process stdin
        if let data = (password + "\n").data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        inPipe.fileHandleForWriting.closeFile()

        // Drain pipes to avoid deadlock, then wait.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdoutStr = String(data: outData, encoding: .utf8) ?? ""
        let stderrStr = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus == 0 { return .verified }

        // Use the full stderr (trimmed) so we don't accidentally eat the real
        // error with over-eager filtering.
        let trimmed = stderrStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.isEmpty ? stdoutStr.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        let exit = process.terminationStatus
        let details = cleaned.isEmpty ? "exit \(exit)" : "\(cleaned) (exit \(exit))"
        return .incorrect(details: details)
    }
}
