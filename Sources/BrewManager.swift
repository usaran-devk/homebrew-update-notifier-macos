import Foundation

/// Manages interaction with the `brew` command-line tool.
///
/// Provides methods to check for outdated packages and to upgrade selected packages.
@MainActor
final class BrewManager: ObservableObject {

    // MARK: - Published Properties

    /// The current update state.
    @Published private(set) var state: UpdateState = .unknown

    /// The list of packages with available updates.
    @Published private(set) var packages: [BrewPackage] = []

    /// Set of selected package names for updating.
    @Published var selectedPackages: Set<String> = []

    /// Per-package update results from the most recent update operation.
    @Published private(set) var updateResults: [PackageUpdateResult] = []

    /// Human-readable summary log from the most recent check operation.
    @Published private(set) var checkLog: String = ""

    // MARK: - Private Properties

    /// Resolved path to the brew executable.
    private let brewPath: String?

    // MARK: - Initialization

    init() {
        if FileManager.default.fileExists(atPath: Constants.Executables.brewARM) {
            brewPath = Constants.Executables.brewARM
        } else if FileManager.default.fileExists(atPath: Constants.Executables.brewIntel) {
            brewPath = Constants.Executables.brewIntel
        } else {
            brewPath = nil
        }
    }

    /// Initializer for testing with an explicit brew path.
    /// - Parameter brewPath: Path to the brew executable.
    init(brewPath: String?) {
        self.brewPath = brewPath
    }

    // MARK: - Check for Updates

    /// Checks for outdated homebrew packages.
    ///
    /// Sets `state` to `.checking` during the operation, then to `.upToDate`
    /// or `.updatesAvailable` depending on results. On failure, sets `.error`.
    func checkForUpdates() async {
        #if DEBUG_MOCK
        state = .checking
        packages = []
        selectedPackages = []
        updateResults = []
        checkLog = ""

        // Simulate network delay
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        packages = Constants.MockData.packages
        selectedPackages = Set(packages.map { $0.name })
        checkLog = BrewManager.buildCheckLog(updateOutput: Constants.MockData.brewUpdateOutput, outdatedOutput: Constants.MockData.brewOutdatedOutput)
        state = .updatesAvailable
        return
        #else
        guard let brewPath else {
            state = .error(L10n.Error.brewNotFound)
            return
        }

        state = .checking
        packages = []
        selectedPackages = []
        updateResults = []
        checkLog = ""

        do {
            // Fetch latest formula/cask definitions before checking
            let updateOutput = try await runProcess(brewPath, arguments: Constants.Process.updateArgs)

            var outdatedArgs = Constants.Process.outdatedArgs
            if Settings.shared.greedyEnabled {
                outdatedArgs.append("--greedy")
            }
            let output = try await runProcess(brewPath, arguments: outdatedArgs)
            let parsed = BrewManager.parseOutdatedJSON(output)
            packages = parsed
            selectedPackages = Set(parsed.map { $0.name })

            // Run plain-text outdated for the check log
            var plainArgs = Constants.Process.outdatedPlainArgs
            if Settings.shared.greedyEnabled {
                plainArgs.append("--greedy")
            }
            let plainOutput = try await runProcess(brewPath, arguments: plainArgs)

            checkLog = BrewManager.buildCheckLog(updateOutput: updateOutput, outdatedOutput: plainOutput)
            state = parsed.isEmpty ? .upToDate : .updatesAvailable
        } catch {
            state = .error(error.localizedDescription)
        }
        #endif
    }

    // MARK: - Update Packages

    /// Upgrades the currently selected packages one by one.
    ///
    /// Sets `state` to `.updating` during the operation.
    /// Populates `updateResults` with per-package status and log output.
    func updateSelectedPackages() async {
        #if DEBUG_MOCK
        let toUpdate = packages.filter { selectedPackages.contains($0.name) }
        guard !toUpdate.isEmpty else { return }

        state = .updating

        // Initialize all results as queued
        updateResults = toUpdate.map { pkg in
            PackageUpdateResult(package: pkg, status: .queued, log: "")
        }

        for i in updateResults.indices {
            updateResults[i].status = .updating

            // For the designated "needs sudo" mock package, optionally exercise
            // the saved-password askpass + a harmless real `sudo -A -n -v` to
            // prove the Keychain integration end-to-end. Only runs when the
            // toggle is on; the password is never written to the log.
            if updateResults[i].package.name == Constants.MockData.sudoPackageName,
               Settings.shared.savedPasswordEnabled,
               let env = BrewManager.makeUpgradeEnvironment(useSavedPassword: true) {
                let askpassReport = await BrewManager.runMockAskpass(env: env)
                updateResults[i].log += askpassReport
                if let sudoReport = await BrewManager.runMockSudoValidate(env: env) {
                    updateResults[i].log += sudoReport
                }
            }

            // Simulate streaming upgrade output
            let lines: [String]
            if updateResults[i].package.name == Constants.MockData.failedPackageName {
                lines = [
                    "==> Upgrading \(updateResults[i].package.name)\n",
                    "==> Downloading...\n",
                    "Error: Mock upgrade failure for \(updateResults[i].package.name)\n",
                ]
            } else {
                lines = [
                    "==> Upgrading \(updateResults[i].package.name)\n",
                    "==> Downloading...\n",
                    "==> Installing \(updateResults[i].package.name)\n",
                    "🍺  \(updateResults[i].package.availableVersion)\n",
                ]
            }

            for line in lines {
                try? await Task.sleep(nanoseconds: 400_000_000)
                updateResults[i].log += line
            }

            // Simulate one failure for demonstration
            if updateResults[i].package.name == Constants.MockData.failedPackageName {
                updateResults[i].status = .failed
            } else {
                updateResults[i].status = .success
            }
        }

        state = .updateComplete(hasErrors: updateResults.contains { $0.status == .failed })
        return
        #else
        guard let brewPath else {
            state = .error(L10n.Error.brewNotFound)
            return
        }

        let toUpdate = packages.filter { selectedPackages.contains($0.name) }
        guard !toUpdate.isEmpty else { return }

        if Settings.shared.savedPasswordEnabled {
            let preflight = BrewManager.preflightSavedPassword()
            switch preflight {
            case .verified:
                break
            case .incorrect(let details):
                state = .error(L10n.Error.savedPasswordInvalid)
                updateResults = toUpdate.map { pkg in
                    PackageUpdateResult(
                        package: pkg,
                        status: .failed,
                        log: "sudo: \(details)\n"
                    )
                }
                return
            case .unavailable(let reason):
                state = .error(L10n.Error.savedPasswordUnavailable)
                updateResults = toUpdate.map { pkg in
                    PackageUpdateResult(
                        package: pkg,
                        status: .failed,
                        log: "sudo: \(reason)\n"
                    )
                }
                return
            }
        }

        state = .updating

        // Initialize all results as queued
        updateResults = toUpdate.map { pkg in
            PackageUpdateResult(package: pkg, status: .queued, log: "")
        }

        let greedy = Settings.shared.greedyEnabled

        // Set up SUDO_ASKPASS so casks requiring sudo show a macOS password dialog
        // (or read the password from the Keychain when enabled).
        let upgradeEnv = BrewManager.makeUpgradeEnvironment(useSavedPassword: Settings.shared.savedPasswordEnabled)

        for i in updateResults.indices {
            updateResults[i].status = .updating

            var args = Constants.Process.upgradeArgs
            if greedy {
                args.append("--greedy")
            }
            args.append(updateResults[i].package.name)

            do {
                try await runProcessStreaming(brewPath, arguments: args, environment: upgradeEnv) { [weak self] chunk in
                    self?.updateResults[i].log += chunk
                }
                // Check output for error patterns (brew may exit 0 even on failure)
                if BrewManager.outputContainsError(updateResults[i].log) {
                    updateResults[i].status = .failed
                } else {
                    updateResults[i].status = .success
                }
            } catch {
                updateResults[i].log += error.localizedDescription
                updateResults[i].status = .failed
            }
        }

        // Set state to update complete (user can press "Check Now" to re-check)
        state = .updateComplete(hasErrors: updateResults.contains { $0.status == .failed })
        #endif
    }

    // MARK: - Selection Helpers

    /// Whether all packages are currently selected.
    var allSelected: Bool {
        !packages.isEmpty && selectedPackages.count == packages.count
    }

    /// Selects or deselects all packages.
    /// - Parameter selected: If `true`, selects all; otherwise deselects all.
    func setAllSelected(_ selected: Bool) {
        if selected {
            selectedPackages = Set(packages.map { $0.name })
        } else {
            selectedPackages = []
        }
    }

    /// Whether all packages of the given type are currently selected.
    /// - Parameter type: The package type (e.g. `Constants.PackageType.formula`).
    func allSelected(forType type: String) -> Bool {
        let typePackages = packages.filter { $0.type == type }
        return !typePackages.isEmpty && typePackages.allSatisfy { selectedPackages.contains($0.name) }
    }

    /// Selects or deselects all packages of the given type.
    /// - Parameters:
    ///   - selected: If `true`, selects all in the group; otherwise deselects all.
    ///   - type: The package type (e.g. `Constants.PackageType.cask`).
    func setAllSelected(_ selected: Bool, forType type: String) {
        let typePackages = packages.filter { $0.type == type }
        if selected {
            typePackages.forEach { selectedPackages.insert($0.name) }
        } else {
            typePackages.forEach { selectedPackages.remove($0.name) }
        }
    }

    /// Toggles selection for a single package.
    /// - Parameter name: The package name to toggle.
    func toggleSelection(_ name: String) {
        if selectedPackages.contains(name) {
            selectedPackages.remove(name)
        } else {
            selectedPackages.insert(name)
        }
    }

    // MARK: - Private Helpers

    /// Builds the check log from raw `brew update` and `brew outdated` output.
    /// - Parameters:
    ///   - updateOutput: Raw output from `brew update`.
    ///   - outdatedOutput: Raw output from `brew outdated` (plain text).
    /// - Returns: A combined log string.
    nonisolated static func buildCheckLog(updateOutput: String = "", outdatedOutput: String = "") -> String {
        var sections: [String] = []

        let trimmedUpdate = updateOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUpdate.isEmpty {
            sections.append(trimmedUpdate)
        }

        let trimmedOutdated = outdatedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOutdated.isEmpty {
            sections.append(trimmedOutdated)
        }

        return sections.joined(separator: "\n\n")
    }

    /// Checks whether process output contains error patterns from brew.
    ///
    /// Homebrew sometimes exits with code 0 even when individual package
    /// upgrades fail. This method scans the output for known error markers.
    /// - Parameter output: The process output string.
    /// - Returns: `true` if the output contains error indicators.
    nonisolated static func outputContainsError(_ output: String) -> Bool {
        output.contains("Error:") || output.contains("sudo: a password is required")
    }

    /// Creates an environment dictionary for `brew upgrade` with `SUDO_ASKPASS` set.
    ///
    /// Generates a temporary askpass script that either:
    /// - prompts the user interactively via `osascript` (default), or
    /// - reads the saved password from the macOS Keychain via `security`
    ///   (when `useSavedPassword` is `true`).
    ///
    /// This allows casks that require `sudo` (e.g., docker-desktop) to
    /// authenticate without printing the password to the UI or to disk in
    /// plain text.
    /// - Parameter useSavedPassword: When `true`, generate a script that
    ///   retrieves the password from the Keychain instead of prompting.
    /// - Returns: Environment variables to merge, or `nil` if creation fails.
    nonisolated static func makeUpgradeEnvironment(useSavedPassword: Bool = false) -> [String: String]? {
        let filename = useSavedPassword
            ? Constants.Process.askpassKeychainFilename
            : Constants.Process.askpassFilename
        let askpassPath = NSTemporaryDirectory() + filename

        // Create askpass script. The interactive variant uses osascript to
        // prompt the user; the keychain variant uses `security` to print the
        // saved password. The keychain variant intentionally writes nothing
        // on stderr so brew never logs hints about the source of the value.
        let script: String
        if useSavedPassword {
            // Use the `security` CLI (always present on macOS) to read the
            // generic password. The first read may trigger a one-time
            // "allow access?" keychain prompt — subsequent reads are silent.
            script = """
            #!/bin/bash
            /usr/bin/security find-generic-password -w -s "\(Constants.Keychain.serviceName)" -a "$USER" 2>/dev/null
            """
        } else {
            script = """
            #!/bin/bash
            /usr/bin/osascript -e 'display dialog "Homebrew needs administrator access to update a package." default answer "" with hidden answer with title "\(Constants.appName)" buttons {"Cancel", "OK"} default button "OK"' -e 'text returned of result' 2>/dev/null
            """
        }

        do {
            try script.write(toFile: askpassPath, atomically: true, encoding: .utf8)
            // Make executable
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: askpassPath
            )
        } catch {
            NSLog("Failed to create askpass helper: \(error)")
            return nil
        }

        return [
            "SUDO_ASKPASS": askpassPath,
            "HOMEBREW_SUDO_THROUGH_SUDO_ASKPASS": "1",
            // Prevent brew from automatically upgrading installed dependents
            // of the requested packages — only upgrade what the user selected.
            "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
            // Reduce noise in the output
            "HOMEBREW_NO_ENV_HINTS": "1",
        ]
    }

    /// Validates the saved sudo password before starting an update batch.
    ///
    /// Uses the same Keychain-backed askpass helper as `brew upgrade` and
    /// invokes `sudo -A -k -v` to confirm the stored value is still accepted.
    ///
    /// Returns `.verified` on success, `.incorrect` on auth failure, and
    /// `.unavailable` when the check cannot be performed.
    nonisolated static func preflightSavedPassword() -> KeychainHelper.VerificationResult {
        guard let env = makeUpgradeEnvironment(useSavedPassword: true) else {
            return .unavailable(reason: "Failed to create askpass helper")
        }
        defer {
            if let askpass = env["SUDO_ASKPASS"] {
                try? FileManager.default.removeItem(atPath: askpass)
            }
        }

        let sudoPath = "/usr/bin/sudo"
        guard FileManager.default.isExecutableFile(atPath: sudoPath) else {
            return .unavailable(reason: "sudo not found at \(sudoPath)")
        }

        let process = Foundation.Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: sudoPath)
        process.arguments = ["-A", "-k", "-v"]
        process.standardOutput = outPipe
        process.standardError = errPipe

        var merged = ProcessInfo.processInfo.environment
        merged.merge(env) { _, new in new }
        process.environment = merged

        do {
            try process.run()
        } catch {
            return .unavailable(reason: "Failed to launch sudo: \(error.localizedDescription)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return .verified
        }

        let stdoutStr = String(data: outData, encoding: .utf8) ?? ""
        let stderrStr = String(data: errData, encoding: .utf8) ?? ""
        let trimmed = stderrStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.isEmpty ? stdoutStr.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        let exit = process.terminationStatus
        let details = cleaned.isEmpty ? "exit \(exit)" : "\(cleaned) (exit \(exit))"
        return .incorrect(details: details)
    }

    #if DEBUG_MOCK
    /// (Mock only) Runs the askpass helper script and returns a redacted
    /// log line reporting the outcome. The actual password value is never
    /// written to the log — only its character count.
    nonisolated static func runMockAskpass(env: [String: String]) async -> String {
        guard let script = env["SUDO_ASKPASS"] else {
            return "==> [mock] askpass: SUDO_ASKPASS not set\n"
        }
        let result = runSyncCapture(path: script, arguments: [], environment: env)
        let pwd = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if pwd.isEmpty {
            return "==> [mock] askpass returned empty (no password stored?) [exit \(result.exitCode)]\n"
        }
        return "==> [mock] askpass returned a password (\(pwd.count) chars) [exit \(result.exitCode)]\n"
    }

    /// (Mock only) Invokes `sudo -A -k -v` with the given environment to
    /// validate that the askpass-supplied password is accepted by PAM.
    /// Returns a redacted log line, or `nil` if `sudo` cannot be found.
    ///
    /// We pass `-k` (invalidate any cached timestamp) and `-A` (use askpass)
    /// but never `-n`: `-n` makes sudo refuse to call askpass and exit with
    /// "a password is required" before the helper is consulted.
    nonisolated static func runMockSudoValidate(env: [String: String]) async -> String? {
        let sudoPath = "/usr/bin/sudo"
        guard FileManager.default.isExecutableFile(atPath: sudoPath) else { return nil }
        let result = runSyncCapture(path: sudoPath, arguments: ["-A", "-k", "-v"], environment: env)
        if result.exitCode == 0 {
            return "==> [mock] sudo validated saved password successfully\n"
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = stderr.split(separator: "\n").first.map(String.init) ?? ""
        return "==> [mock] sudo rejected saved password [exit \(result.exitCode)] \(firstLine)\n"
    }

    /// (Mock only) Synchronous process runner used by the mock helpers.
    /// Returns stdout, stderr, and exit code. Never throws.
    nonisolated private static func runSyncCapture(
        path: String,
        arguments: [String],
        environment: [String: String]?
    ) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Foundation.Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        var merged = ProcessInfo.processInfo.environment
        if let environment { merged.merge(environment) { _, new in new } }
        process.environment = merged
        do {
            try process.run()
        } catch {
            return ("", "\(error)", -1)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }
    #endif

    /// Thread-safe accumulator for process output used during streaming.
    private final class OutputAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""

        func append(_ chunk: String) {
            lock.lock()
            buffer += chunk
            lock.unlock()
        }

        var value: String {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    /// Runs a process, streaming output chunks to the caller via `onOutput`.
    ///
    /// Each chunk is delivered on the main actor so callers can safely update
    /// `@Published` properties. The full output is also returned when the
    /// process completes.

    /// Runs a process and returns its standard output as a string.
    /// - Parameters:
    ///   - path: Path to the executable.
    ///   - arguments: Arguments to pass.
    /// - Returns: The stdout output.
    private func runProcess(_ path: String, arguments: [String]) async throws -> String {
        try await runProcessStreaming(path, arguments: arguments, environment: nil, onOutput: nil)
    }

    /// Runs a process with streaming output support.
    /// - Parameters:
    ///   - path: Path to the executable.
    ///   - arguments: Arguments to pass.
    ///   - environment: Optional custom environment variables. Merged with current process env.
    ///   - onOutput: Optional callback invoked with each chunk of output as it arrives.
    /// - Returns: The complete stdout/stderr output.
    @discardableResult
    private func runProcessStreaming(
        _ path: String,
        arguments: [String],
        environment: [String: String]?,
        onOutput: (@Sendable @MainActor (String) -> Void)?
    ) async throws -> String {
        let executableURL = URL(fileURLWithPath: path)
        var mergedEnv = ProcessInfo.processInfo.environment
        if let environment {
            mergedEnv.merge(environment) { _, new in new }
        }
        let env = mergedEnv

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Foundation.Process()
                let pipe = Pipe()

                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                process.environment = env

                let accumulator = OutputAccumulator()

                // Stream chunks if callback provided
                if let onOutput {
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        if let chunk = String(data: data, encoding: .utf8) {
                            accumulator.append(chunk)
                            DispatchQueue.main.async {
                                onOutput(chunk)
                            }
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }

                if let onOutput {
                    // Wait for process to finish, then clean up handler
                    process.waitUntilExit()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    // Read any remaining data
                    let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let chunk = String(data: remaining, encoding: .utf8), !chunk.isEmpty {
                        accumulator.append(chunk)
                        DispatchQueue.main.async {
                            onOutput(chunk)
                        }
                    }
                    continuation.resume(returning: accumulator.value)
                } else {
                    // Non-streaming: read all at once (avoids pipe buffer deadlock)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                }
            }
        }
    }

    /// Parses the JSON output of `brew outdated --json=v2`.
    /// - Parameter json: The raw JSON string.
    /// - Returns: An array of `BrewPackage` with update info.
    nonisolated static func parseOutdatedJSON(_ json: String) -> [BrewPackage] {
        guard let data = json.data(using: .utf8) else { return [] }

        struct OutdatedResponse: Decodable {
            struct Formula: Decodable {
                let name: String
                let installed_versions: [String]
                let current_version: String
            }
            struct Cask: Decodable {
                let name: String
                let installed_versions: [String]
                let current_version: String
            }
            let formulae: [Formula]?
            let casks: [Cask]?
        }

        do {
            let response = try JSONDecoder().decode(OutdatedResponse.self, from: data)
            var result: [BrewPackage] = []

            if let formulae = response.formulae {
                for f in formulae {
                    result.append(BrewPackage(
                        type: Constants.PackageType.formula,
                        name: f.name,
                        installedVersion: f.installed_versions.last ?? "?",
                        availableVersion: f.current_version
                    ))
                }
            }

            if let casks = response.casks {
                for c in casks {
                    result.append(BrewPackage(
                        type: Constants.PackageType.cask,
                        name: c.name,
                        installedVersion: c.installed_versions.last ?? "?",
                        availableVersion: c.current_version
                    ))
                }
            }

            return result
        } catch {
            NSLog("Failed to parse brew outdated JSON: \(error)")
            return []
        }
    }
}
