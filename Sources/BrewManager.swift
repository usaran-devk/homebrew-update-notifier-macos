import Foundation

/// Manages interaction with the `brew` command-line tool.
///
/// Provides methods to check for outdated packages and to upgrade selected packages.
/// Parsing logic lives in `BrewParser`, graph algorithms in `DependencyResolver`,
/// and process execution in `ProcessRunner`.
@MainActor
final class BrewManager: ObservableObject {

    // MARK: - Published Properties

    /// The current update state.
    @Published private(set) var state: UpdateState = .unknown

    /// The list of packages with available updates.
    @Published private(set) var packages: [BrewPackage] = []

    /// Set of selected package names for updating.
    @Published var selectedPackages: Set<String> = []

    /// Direct dependencies between outdated packages (name -> direct deps).
    @Published private(set) var dependencyGraph: [String: [String]] = [:]

    /// Per-package update results from the most recent update operation.
    @Published private(set) var updateResults: [PackageUpdateResult] = []

    /// Human-readable summary log from the most recent check operation.
    @Published private(set) var checkLog: String = ""
    @Published private(set) var checkTime: Date?

    // MARK: - Private Properties

    /// Resolved path to the brew executable.
    private let brewPath: String?

    /// Process runner used to launch brew subcommands.
    private let processRunner = ProcessRunner()

    /// True while an update workflow is active (preflight + upgrade execution).
    private var isUpdateInProgress = false

    #if DEBUG_MOCK
    /// Toggles each update run: when `true` packages may fail randomly; when `false` all succeed.
    private var mockFailureEnabled = false
    #endif

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
    /// or `.updatesAvailable` depending on results. On failure, sets `.checkError`.
    func checkForUpdates() async {
        // Ignore background checks while another check/update is active to keep
        // state transitions deterministic (for UI and dock icon behavior).
        if isUpdateInProgress || state == .updating || state == .checking {
            return
        }

        #if DEBUG_MOCK
        state = .checking
        packages = []
        selectedPackages = []
        dependencyGraph = [:]
        updateResults = []
        checkLog = ""
        checkTime = Date()

        // Simulate network delay
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Another operation may have changed state while this check was waiting.
        guard state == .checking, !isUpdateInProgress else {
            return
        }

        if Bool.random() {
            // Each package has a 50% base chance of being selected.
            // For any selected package, each of its dependencies gets an
            // additional 50% chance to be pulled in as well.
            var selectedNames = Set(Constants.MockData.packages
                .filter { _ in Bool.random() }
                .map { $0.name })
            // Ensure at least one package is always selected
            if selectedNames.isEmpty, let pick = Constants.MockData.packages.randomElement() {
                selectedNames.insert(pick.name)
            }
            // Dependency bonus pass
            for name in selectedNames {
                for dep in Constants.MockData.dependencyGraph[name] ?? [] {
                    if !selectedNames.contains(dep), Bool.random() {
                        selectedNames.insert(dep)
                    }
                }
            }
            packages = Constants.MockData.packages.filter { selectedNames.contains($0.name) }
            selectedPackages = Set(packages.map { $0.name })
            dependencyGraph = Constants.MockData.dependencyGraph.filter { selectedNames.contains($0.key) }
            checkLog = BrewParser.buildCheckLog(updateOutput: Constants.MockData.brewUpdateOutput, outdatedOutput: Constants.MockData.brewOutdatedOutput)
            state = .updatesAvailable
        } else {
            // No updates available
            packages = []
            selectedPackages = []
            dependencyGraph = [:]
            checkLog = BrewParser.buildCheckLog(updateOutput: Constants.MockData.brewUpdateOutput, outdatedOutput: "")
            state = .upToDate
        }
        return
        #else
        guard let brewPath else {
            state = .checkError(L10n.Error.brewNotFound)
            return
        }

        state = .checking
        packages = []
        selectedPackages = []
        dependencyGraph = [:]
        updateResults = []
        checkLog = ""
        do {
            // Fetch latest formula/cask definitions before checking.
            let updateOutput = try await processRunner.run(brewPath, arguments: Constants.Process.updateArgs)
            guard state == .checking, !isUpdateInProgress else {
                return
            }
            if BrewParser.outputContainsError(updateOutput) {
                setCheckErrorState(messageFrom: updateOutput, updateOutput: updateOutput, outdatedOutput: "")
                return
            }

            var outdatedArgs = Constants.Process.outdatedArgs
            if Settings.shared.greedyEnabled {
                outdatedArgs.append("--greedy")
            }
            let output = try await processRunner.run(brewPath, arguments: outdatedArgs)
            guard state == .checking, !isUpdateInProgress else {
                return
            }
            if BrewParser.outputContainsError(output) {
                setCheckErrorState(messageFrom: output, updateOutput: updateOutput, outdatedOutput: output)
                return
            }
            let parsed = BrewParser.parseOutdatedJSON(output)
            packages = parsed
            selectedPackages = Set(parsed.map { $0.name })
            dependencyGraph = await resolveDependencies(for: parsed)

            // Run plain-text outdated for the check log.
            var plainArgs = Constants.Process.outdatedPlainArgs
            if Settings.shared.greedyEnabled {
                plainArgs.append("--greedy")
            }
            let plainOutput = try await processRunner.run(brewPath, arguments: plainArgs)
            guard state == .checking, !isUpdateInProgress else {
                return
            }
            if BrewParser.outputContainsError(plainOutput) {
                setCheckErrorState(messageFrom: plainOutput, updateOutput: updateOutput, outdatedOutput: plainOutput)
                return
            }

            checkLog = BrewParser.buildCheckLog(updateOutput: updateOutput, outdatedOutput: plainOutput)
            checkTime = Date()
            guard state == .checking, !isUpdateInProgress else {
                return
            }
            state = parsed.isEmpty ? .upToDate : .updatesAvailable
        } catch {
            // Ignore stale errors from a check superseded by another state.
            guard state == .checking, !isUpdateInProgress else {
                return
            }
            state = .checkError(error.localizedDescription)
        }
        #endif
    }

    /// Sets a dedicated check error state and captures a useful check log.
    /// - Parameters:
    ///   - output: Process output that contains an error marker.
    ///   - updateOutput: Raw output from `brew update`.
    ///   - outdatedOutput: Raw output from `brew outdated`.
    private func setCheckErrorState(messageFrom output: String, updateOutput: String, outdatedOutput: String) {
        guard state == .checking, !isUpdateInProgress else {
            return
        }

        let fallback = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map(String.init)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let message = BrewParser.firstErrorLine(in: output) ?? fallback ?? L10n.State.checkError

        state = .checkError(message)
        checkLog = BrewParser.buildCheckLog(updateOutput: updateOutput, outdatedOutput: outdatedOutput)
        checkTime = Date()
    }

    // MARK: - Update Packages

    /// Builds the correct Homebrew arguments for upgrading or forcing a reinstall.
    ///
    /// `brew upgrade --force` is not a reliable repair command for a broken or
    /// stale installation; the repair path should use `brew reinstall --force`.
    /// - Parameters:
    ///   - package: The package to upgrade.
    ///   - greedy: Whether to include `--greedy` for cask upgrades.
    ///   - forceUpgrade: Whether the install should be forced with a reinstall.
    /// - Returns: The normalized argument array for the brew subcommand.
    static func buildUpgradeArguments(package: BrewPackage, greedy: Bool, forceUpgrade: Bool) -> [String] {
        let command: String = forceUpgrade ? "reinstall" : "upgrade"
        var args = [command]

        if !forceUpgrade && greedy {
            args.append("--greedy")
        }

        if forceUpgrade {
            args.append("--force")
        }

        if package.type == Constants.PackageType.cask {
            args.append("--cask")
        }

        args.append(package.name)
        return args
    }

    /// Upgrades the currently selected packages one by one.
    ///
    /// Sets `state` to `.updating` during the operation.
    /// Populates `updateResults` with per-package status and log output.
    func updateSelectedPackages(forceUpgrade: Bool = false) async {
        // Prevent overlapping update workflows and block background checks for
        // the full duration (including any preflight work before `.updating`).
        guard !isUpdateInProgress else { return }

        #if DEBUG_MOCK
        let toUpdate = packages.filter { selectedPackages.contains($0.name) }
        guard !toUpdate.isEmpty else { return }
        isUpdateInProgress = true
        defer { isUpdateInProgress = false }
        let orderedToUpdate = DependencyResolver.orderPackagesForUpdate(toUpdate, dependencyGraph: dependencyGraph)

        // Toggle failure mode: odd runs may fail, even runs always succeed
        mockFailureEnabled.toggle()
        let failureEnabled = mockFailureEnabled

        state = .updating

        // Initialize all results as queued
        updateResults = orderedToUpdate.map { pkg in
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

            // Randomly determine if this package upgrade fails (~10% chance, only when failure mode is active)
            let shouldFail = failureEnabled && Double.random(in: 0..<1) < 0.1

            // Simulate streaming upgrade output
            let lines: [String]
            if shouldFail {
                lines = [
                    "==> Upgrading \(updateResults[i].package.name)\n",
                    "==> Downloading...\n",
                    "######################################################################### 100.0%\n",
                    "==> Extracting \(updateResults[i].package.name) from archive\n",
                    "==> Running post-install procedures\n",
                    "==> Verifying package integrity\n",
                    "==> Building and installing \(updateResults[i].package.name)...\n",
                    "🔨 Building \(updateResults[i].package.name) with dependencies...\n",
                    "⏳ Compilation stage 1 of 5: Preprocessing\n",
                    "⏳ Compilation stage 2 of 5: Configuration check\n",
                    "⏳ Compilation stage 3 of 5: Build\n",
                    "⏳ Compilation stage 4 of 5: Testing build artifacts\n",
                    "❌ Error during testing phase\n",
                    "Error: Mock upgrade failure for \(updateResults[i].package.name)\n",
                    "Build failed at stage 4 of 5\n",
                    "See log file: /var/log/\(updateResults[i].package.name).log\n",
                ]
            } else {
                lines = [
                    "==> Upgrading \(updateResults[i].package.name)\n",
                    "==> Downloading...\n",
                    "######################################################################### 100.0%\n",
                    "==> Extracting \(updateResults[i].package.name) from archive\n",
                    "==> Running post-install procedures\n",
                    "==> Verifying package integrity\n",
                    "==> Building and installing \(updateResults[i].package.name)...\n",
                    "🔨 Building \(updateResults[i].package.name) with dependencies...\n",
                    "⏳ Compilation stage 1 of 5: Preprocessing\n",
                    "⏳ Compilation stage 2 of 5: Configuration check\n",
                    "⏳ Compilation stage 3 of 5: Build\n",
                    "⏳ Compilation stage 4 of 5: Testing build artifacts\n",
                    "✅ All tests passed\n",
                    "⏳ Compilation stage 5 of 5: Installation\n",
                    "==> Installing \(updateResults[i].package.name)\n",
                    "🍺  \(updateResults[i].package.name) \(updateResults[i].package.availableVersion) has been successfully installed\n",
                    "==> Cleanup\n",
                    "==> Removing old files\n",
                    "✅ Installation complete\n",
                ]
            }

            for line in lines {
                try? await Task.sleep(nanoseconds: 400_000_000)
                updateResults[i].log += line
            }

            updateResults[i].status = shouldFail ? .failed : .success
        }

        pruneSuccessfullyUpdatedPackagesFromCache()
        state = .updateComplete(hasErrors: updateResults.contains { $0.status == .failed })
        return
        #else
        guard let brewPath else {
            state = .error(L10n.Error.brewNotFound)
            return
        }

        let toUpdate = packages.filter { selectedPackages.contains($0.name) }
        guard !toUpdate.isEmpty else { return }
        isUpdateInProgress = true
        defer { isUpdateInProgress = false }
        let orderedToUpdate = DependencyResolver.orderPackagesForUpdate(toUpdate, dependencyGraph: dependencyGraph)

        state = .updating

        if Settings.shared.savedPasswordEnabled {
            let preflight = BrewManager.preflightSavedPassword()
            switch preflight {
            case .verified:
                break
            case .incorrect(let details):
                state = .error(L10n.Error.savedPasswordInvalid)
                updateResults = orderedToUpdate.map { pkg in
                    PackageUpdateResult(
                        package: pkg,
                        status: .failed,
                        log: "sudo: \(details)\n"
                    )
                }
                return
            case .unavailable(let reason):
                state = .error(L10n.Error.savedPasswordUnavailable)
                updateResults = orderedToUpdate.map { pkg in
                    PackageUpdateResult(
                        package: pkg,
                        status: .failed,
                        log: "sudo: \(reason)\n"
                    )
                }
                return
            }
        }

        // Initialize all results as queued.
        updateResults = orderedToUpdate.map { pkg in
            PackageUpdateResult(package: pkg, status: .queued, log: "")
        }

        let greedy = Settings.shared.greedyEnabled

        // Set up SUDO_ASKPASS so casks requiring sudo show a macOS password dialog
        // (or read the password from the Keychain when enabled).
        let upgradeEnv = BrewManager.makeUpgradeEnvironment(useSavedPassword: Settings.shared.savedPasswordEnabled)

        for i in updateResults.indices {
            updateResults[i].status = .updating

            let args = BrewManager.buildUpgradeArguments(
                package: updateResults[i].package,
                greedy: greedy,
                forceUpgrade: forceUpgrade
            )

            do {
                try await processRunner.runStreaming(brewPath, arguments: args, environment: upgradeEnv) { [weak self] chunk in
                    self?.updateResults[i].log += chunk
                }
                // Check output for error patterns (brew may exit 0 even on failure).
                if BrewParser.outputContainsError(updateResults[i].log) {
                    updateResults[i].status = .failed
                } else {
                    updateResults[i].status = .success
                }
            } catch {
                updateResults[i].log += error.localizedDescription
                updateResults[i].status = .failed
            }
        }

        pruneSuccessfullyUpdatedPackagesFromCache()
        // Set state to update complete (user can press "Check Now" to re-check).
        state = .updateComplete(hasErrors: updateResults.contains { $0.status == .failed })
        #endif
    }

    /// Removes successfully updated packages from the cached outdated-package
    /// data so post-update UI and icon state reflect what still remains.
    private func pruneSuccessfullyUpdatedPackagesFromCache() {
        let successfulNames = Set(updateResults.compactMap { result in
            result.status == .success ? result.package.name : nil
        })
        guard !successfulNames.isEmpty else { return }

        packages = packages.filter { !successfulNames.contains($0.name) }
        let available = Set(packages.map { $0.name })
        dependencyGraph = dependencyGraph
            .filter { available.contains($0.key) }
            .mapValues { deps in deps.filter { available.contains($0) } }
        selectedPackages = selectedPackages.intersection(available)
    }

    /// Selected packages sorted so dependencies are updated before dependents.
    var selectedPackagesInDependencyOrder: [BrewPackage] {
        let selected = packages.filter { selectedPackages.contains($0.name) }
        return DependencyResolver.orderPackagesForUpdate(selected, dependencyGraph: dependencyGraph)
    }

    /// Selected package names that are part of a dependency cycle.
    var selectedDependencyCycleNodes: [String] {
        let selected = packages.filter { selectedPackages.contains($0.name) }
        return DependencyResolver.dependencyCycleNodes(packages: selected, dependencyGraph: dependencyGraph)
    }

    /// Whether the package list can be switched back to remaining outdated items
    /// using cached data from the most recent update run.
    var canShowRemainingPackagesAfterUpdate: Bool {
        guard state.isUpdateComplete else { return false }
        let successfulNames = Set(updateResults.compactMap { result in
            result.status == .success ? result.package.name : nil
        })
        return packages.contains { !successfulNames.contains($0.name) }
    }

    /// Switches UI state from update results back to the remaining outdated
    /// package list without running `brew update`/`brew outdated` again.
    ///
    /// This is a best-effort local refresh based on the previous check and
    /// per-package update outcomes of the latest update run.
    func showRemainingPackagesAfterUpdate() {
        guard state.isUpdateComplete else { return }

        pruneSuccessfullyUpdatedPackagesFromCache()

        state = packages.isEmpty ? .upToDate : .updatesAvailable
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
            let combined = selectedPackages.union(typePackages.map { $0.name })
            selectedPackages = selectedNamesIncludingDependencies(from: combined)
        } else {
            let names = Set(typePackages.map { $0.name })
            selectedPackages = selectedNamesAfterDeselection(of: names)
        }
    }

    /// Toggles selection for a single package.
    /// - Parameter name: The package name to toggle.
    func toggleSelection(_ name: String) {
        if selectedPackages.contains(name) {
            selectedPackages = selectedNamesAfterDeselection(of: [name])
        } else {
            let combined = selectedPackages.union([name])
            selectedPackages = selectedNamesIncludingDependencies(from: combined)
        }
    }

    /// Expands selected names to include all transitive dependencies that are
    /// currently part of the outdated package list.
    private func selectedNamesIncludingDependencies(from names: Set<String>) -> Set<String> {
        let expanded = DependencyResolver.expandedSelectionIncludingDependencies(
            selectedNames: names,
            dependencyGraph: dependencyGraph
        )
        let available = Set(packages.map { $0.name })
        return expanded.intersection(available)
    }

    /// Removes deselected names and all selected packages that depend on them.
    private func selectedNamesAfterDeselection(of names: Set<String>) -> Set<String> {
        let updated = DependencyResolver.selectionAfterDeselectionRemovingDependents(
            selectedNames: selectedPackages,
            deselectedNames: names,
            dependencyGraph: dependencyGraph
        )
        let available = Set(packages.map { $0.name })
        return updated.intersection(available)
    }

    // MARK: - Dependency Resolution

    /// Resolves dependencies for the provided outdated packages using `brew deps`.
    ///
    /// Only dependencies that are also present in `packages` are retained.
    private func resolveDependencies(for packages: [BrewPackage]) async -> [String: [String]] {
        guard let brewPath else { return [:] }

        let packageNames = Set(packages.map { $0.name })
        var graph: [String: [String]] = [:]

        for pkg in packages {
            var args = ["deps", "--1"]
            if pkg.type == Constants.PackageType.cask {
                args.append("--cask")
            }
            args.append(pkg.name)

            do {
                let output = try await processRunner.run(brewPath, arguments: args)
                let deps = output
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && packageNames.contains($0) }
                graph[pkg.name] = deps
            } catch {
                graph[pkg.name] = []
            }
        }

        return graph
    }

    // MARK: - Upgrade Environment

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

    // MARK: - Password Preflight

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

    // MARK: - Mock Helpers

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
}
