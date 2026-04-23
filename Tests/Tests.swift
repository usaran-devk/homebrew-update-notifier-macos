import Foundation

// MARK: - Test Framework

/// Simple test framework mimicking describe/it pattern.

/// Test runner runs single-threaded so these are safe.
nonisolated(unsafe) private var totalTests = 0
nonisolated(unsafe) private var passedTests = 0
nonisolated(unsafe) private var failedTests = 0
nonisolated(unsafe) private var currentDescribe = ""

func describe(_ name: String, _ block: () -> Void) {
    currentDescribe = name
    print("  \(name)")
    block()
}

func it(_ name: String, _ block: () throws -> Void) {
    totalTests += 1
    do {
        try block()
        passedTests += 1
        print("    ✓ \(name)")
    } catch {
        failedTests += 1
        print("    ✗ \(name): \(error)")
    }
}

struct TestFailure: Error {
    let message: String
}

func expect<T: Equatable>(_ actual: T, _ expected: T, file: String = #file, line: Int = #line) throws {
    if actual != expected {
        throw TestFailure(message: "Expected \(expected), got \(actual) at \(file):\(line)")
    }
}

func expectTrue(_ value: Bool, file: String = #file, line: Int = #line) throws {
    if !value {
        throw TestFailure(message: "Expected true, got false at \(file):\(line)")
    }
}

func expectFalse(_ value: Bool, file: String = #file, line: Int = #line) throws {
    if value {
        throw TestFailure(message: "Expected false, got true at \(file):\(line)")
    }
}

func expectNil<T>(_ value: T?, file: String = #file, line: Int = #line) throws {
    if value != nil {
        throw TestFailure(message: "Expected nil, got \(value!) at \(file):\(line)")
    }
}

func expectNotNil<T>(_ value: T?, file: String = #file, line: Int = #line) throws {
    if value == nil {
        throw TestFailure(message: "Expected non-nil at \(file):\(line)")
    }
}

// MARK: - Test Runner

enum TestRunner {
    static func main() {
        print("Running tests...\n")

        testConstants()
        testLocalization()
        testUpdateState()
        testSettings()
        testBrewManagerParsing()

        print("\n\(totalTests) tests, \(passedTests) passed, \(failedTests) failed")

        if failedTests > 0 {
            exit(1)
        }
    }
}

// MARK: - Constants Tests

func testConstants() {
    describe("Constants.Executables") {
        it("has ARM brew path") {
            try expect(Constants.Executables.brewARM, "/opt/homebrew/bin/brew")
        }
        it("has Intel brew path") {
            try expect(Constants.Executables.brewIntel, "/usr/local/bin/brew")
        }
    }

    describe("Constants.Defaults") {
        it("has default check interval of 60") {
            try expect(Constants.Defaults.checkIntervalMinutes, 60)
        }
        it("has min check interval of 5") {
            try expect(Constants.Defaults.minCheckIntervalMinutes, 5)
        }
        it("has max check interval of 1440") {
            try expect(Constants.Defaults.maxCheckIntervalMinutes, 1440)
        }
    }

    describe("Constants.StorageKeys") {
        it("has checkInterval key") {
            try expect(Constants.StorageKeys.checkInterval, "checkIntervalMinutes")
        }
        it("has autostart key") {
            try expect(Constants.StorageKeys.autostart, "autostartEnabled")
        }
        it("has savedPasswordEnabled key") {
            try expect(Constants.StorageKeys.savedPasswordEnabled, "savedPasswordEnabled")
        }
    }

    describe("Constants.Keychain") {
        it("has a stable service name") {
            try expect(Constants.Keychain.serviceName, "de.devk.homebrew-update-notifier.sudo")
        }
    }

    describe("Constants.Process") {
        it("has distinct askpass filenames for interactive and keychain modes") {
            try expectFalse(Constants.Process.askpassFilename == Constants.Process.askpassKeychainFilename)
        }
    }

    describe("Constants.Symbols") {
        it("has base symbol") {
            try expect(Constants.Symbols.base, "mug.fill")
        }
        it("has badgeUpToDate symbol") {
            try expect(Constants.Symbols.badgeUpToDate, "checkmark.circle.fill")
        }
        it("has badgeUpdatesAvailable symbol") {
            try expect(Constants.Symbols.badgeUpdatesAvailable, "exclamationmark.circle.fill")
        }
        it("has badgeChecking symbol") {
            try expect(Constants.Symbols.badgeChecking, "arrow.triangle.2.circlepath.circle.fill")
        }
        it("has badgeError symbol") {
            try expect(Constants.Symbols.badgeError, "xmark.circle.fill")
        }
        it("has badgeUpdating symbol") {
            try expect(Constants.Symbols.badgeUpdating, "tray.and.arrow.down.fill")
        }
    }
}

// MARK: - Localization Tests

func testLocalization() {
    describe("Localization.State") {
        it("upToDate is not empty") {
            try expectFalse(L10n.State.upToDate.isEmpty)
        }
        it("updatesAvailable is not empty") {
            try expectFalse(L10n.State.updatesAvailable.isEmpty)
        }
        it("checking is not empty") {
            try expectFalse(L10n.State.checking.isEmpty)
        }
        it("updating is not empty") {
            try expectFalse(L10n.State.updating.isEmpty)
        }
        it("updateComplete is not empty") {
            try expectFalse(L10n.State.updateComplete.isEmpty)
        }
        it("updateCompletedWithErrors is not empty") {
            try expectFalse(L10n.State.updateCompletedWithErrors.isEmpty)
        }
        it("error is not empty") {
            try expectFalse(L10n.State.error.isEmpty)
        }
    }

    describe("Localization.Menu") {
        it("selectAll is not empty") {
            try expectFalse(L10n.Menu.selectAll.isEmpty)
        }
        it("quit is not empty") {
            try expectFalse(L10n.Menu.quit.isEmpty)
        }
    }

    describe("Localization.Settings") {
        it("title is not empty") {
            try expectFalse(L10n.Settings.title.isEmpty)
        }
        it("checkInterval is not empty") {
            try expectFalse(L10n.Settings.checkInterval.isEmpty)
        }
    }

    describe("Localization.Error") {
        it("brewNotFound is not empty") {
            try expectFalse(L10n.Error.brewNotFound.isEmpty)
        }
        it("savedPasswordInvalid is not empty") {
            try expectFalse(L10n.Error.savedPasswordInvalid.isEmpty)
        }
        it("savedPasswordUnavailable is not empty") {
            try expectFalse(L10n.Error.savedPasswordUnavailable.isEmpty)
        }
    }
}

// MARK: - UpdateState Tests

func testUpdateState() {
    describe("UpdateState") {
        it("unknown uses checking badge") {
            try expect(UpdateState.unknown.badgeSymbolName, Constants.Symbols.badgeChecking)
        }
        it("checking uses checking badge") {
            try expect(UpdateState.checking.badgeSymbolName, Constants.Symbols.badgeChecking)
        }
        it("upToDate uses upToDate badge") {
            try expect(UpdateState.upToDate.badgeSymbolName, Constants.Symbols.badgeUpToDate)
        }
        it("updatesAvailable uses updatesAvailable badge") {
            try expect(UpdateState.updatesAvailable.badgeSymbolName, Constants.Symbols.badgeUpdatesAvailable)
        }
        it("updating uses updating badge") {
            try expect(UpdateState.updating.badgeSymbolName, Constants.Symbols.badgeUpdating)
        }
        it("updateComplete uses upToDate badge when no errors") {
            try expect(UpdateState.updateComplete(hasErrors: false).badgeSymbolName, Constants.Symbols.badgeUpToDate)
        }
        it("updateComplete uses error badge when has errors") {
            try expect(UpdateState.updateComplete(hasErrors: true).badgeSymbolName, Constants.Symbols.badgeError)
        }
        it("updateComplete statusText is not empty") {
            try expectFalse(UpdateState.updateComplete(hasErrors: false).statusText.isEmpty)
        }
        it("updateComplete with errors has different statusText") {
            let success = UpdateState.updateComplete(hasErrors: false).statusText
            let withErrors = UpdateState.updateComplete(hasErrors: true).statusText
            try expectFalse(success == withErrors)
        }
        it("updateComplete is not an error") {
            try expectFalse(UpdateState.updateComplete(hasErrors: false).isError)
        }
        it("updateComplete isUpdateComplete returns true") {
            try expectTrue(UpdateState.updateComplete(hasErrors: false).isUpdateComplete)
            try expectTrue(UpdateState.updateComplete(hasErrors: true).isUpdateComplete)
        }
        it("error uses error badge") {
            try expect(UpdateState.error("test").badgeSymbolName, Constants.Symbols.badgeError)
        }
        it("isError returns true for error state") {
            try expectTrue(UpdateState.error("test").isError)
        }
        it("isError returns false for non-error states") {
            try expectFalse(UpdateState.upToDate.isError)
            try expectFalse(UpdateState.checking.isError)
        }
        it("statusText returns localized string") {
            try expectFalse(UpdateState.upToDate.statusText.isEmpty)
        }
    }

    describe("BrewPackage") {
        it("id equals name") {
            let pkg = BrewPackage(type: Constants.PackageType.formula, name: "wget", installedVersion: "1.0", availableVersion: "2.0")
            try expect(pkg.id, "wget")
        }
        it("supports equality") {
            let a = BrewPackage(type: Constants.PackageType.formula, name: "wget", installedVersion: "1.0", availableVersion: "2.0")
            let b = BrewPackage(type: Constants.PackageType.formula, name: "wget", installedVersion: "1.0", availableVersion: "2.0")
            try expect(a, b)
        }
    }
}

// MARK: - Settings Tests

func testSettings() {
    describe("Settings") {
        it("checkIntervalSeconds converts correctly") {
            let settings = Settings.shared
            let original = settings.checkIntervalMinutes
            settings.checkIntervalMinutes = 30
            try expect(settings.checkIntervalSeconds, 1800.0)
            // Restore
            settings.checkIntervalMinutes = original
        }

        it("clamps interval to minimum") {
            let settings = Settings.shared
            let original = settings.checkIntervalMinutes
            settings.checkIntervalMinutes = 1
            try expect(settings.checkIntervalMinutes, Constants.Defaults.minCheckIntervalMinutes)
            settings.checkIntervalMinutes = original
        }

        it("clamps interval to maximum") {
            let settings = Settings.shared
            let original = settings.checkIntervalMinutes
            settings.checkIntervalMinutes = 9999
            try expect(settings.checkIntervalMinutes, Constants.Defaults.maxCheckIntervalMinutes)
            settings.checkIntervalMinutes = original
        }

        it("greedy defaults to true") {
            let settings = Settings.shared
            let original = settings.greedyEnabled
            // Remove the key to test the default
            UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.greedy)
            try expectTrue(settings.greedyEnabled)
            settings.greedyEnabled = original
        }

        it("greedy can be toggled") {
            let settings = Settings.shared
            let original = settings.greedyEnabled
            settings.greedyEnabled = true
            try expectTrue(settings.greedyEnabled)
            settings.greedyEnabled = false
            try expectFalse(settings.greedyEnabled)
            settings.greedyEnabled = original
        }

        it("savedPasswordEnabled defaults to false") {
            let settings = Settings.shared
            let original = settings.savedPasswordEnabled
            UserDefaults.standard.removeObject(forKey: Constants.StorageKeys.savedPasswordEnabled)
            try expectFalse(settings.savedPasswordEnabled)
            settings.savedPasswordEnabled = original
        }

        it("savedPasswordEnabled can be toggled") {
            let settings = Settings.shared
            let original = settings.savedPasswordEnabled
            settings.savedPasswordEnabled = true
            try expectTrue(settings.savedPasswordEnabled)
            settings.savedPasswordEnabled = false
            try expectFalse(settings.savedPasswordEnabled)
            settings.savedPasswordEnabled = original
        }
    }
}

// MARK: - BrewManager Parsing Tests

func testBrewManagerParsing() {
    describe("BrewManager.parseOutdatedJSON") {
        it("parses empty JSON") {
            let result = BrewManager.parseOutdatedJSON("{}")
            try expect(result.count, 0)
        }

        it("parses formulae") {
            let json = """
            {
                "formulae": [
                    {
                        "name": "wget",
                        "installed_versions": ["1.21"],
                        "current_version": "1.24"
                    }
                ],
                "casks": []
            }
            """
            let result = BrewManager.parseOutdatedJSON(json)
            try expect(result.count, 1)
            try expect(result[0].name, "wget")
            try expect(result[0].installedVersion, "1.21")
            try expect(result[0].availableVersion, "1.24")
            try expect(result[0].type, Constants.PackageType.formula)
        }

        it("parses casks") {
            let json = """
            {
                "formulae": [],
                "casks": [
                    {
                        "name": "firefox",
                        "installed_versions": ["120.0"],
                        "current_version": "121.0"
                    }
                ]
            }
            """
            let result = BrewManager.parseOutdatedJSON(json)
            try expect(result.count, 1)
            try expect(result[0].name, "firefox")
            try expect(result[0].installedVersion, "120.0")
            try expect(result[0].availableVersion, "121.0")
            try expect(result[0].type, Constants.PackageType.cask)
        }

        it("parses mixed formulae and casks") {
            let json = """
            {
                "formulae": [
                    {
                        "name": "wget",
                        "installed_versions": ["1.21"],
                        "current_version": "1.24"
                    }
                ],
                "casks": [
                    {
                        "name": "firefox",
                        "installed_versions": ["120.0"],
                        "current_version": "121.0"
                    }
                ]
            }
            """
            let result = BrewManager.parseOutdatedJSON(json)
            try expect(result.count, 2)
        }

        it("returns empty for invalid JSON") {
            let result = BrewManager.parseOutdatedJSON("not json")
            try expect(result.count, 0)
        }
    }

    describe("BrewManager.buildCheckLog") {
        it("returns empty string when both outputs are empty") {
            let log = BrewManager.buildCheckLog()
            try expect(log, "")
        }

        it("includes brew update output") {
            let log = BrewManager.buildCheckLog(updateOutput: "Updated 1 tap.")
            try expect(log, "Updated 1 tap.")
        }

        it("includes brew outdated output") {
            let log = BrewManager.buildCheckLog(outdatedOutput: "wget (1.0) < 2.0")
            try expect(log, "wget (1.0) < 2.0")
        }

        it("combines both outputs with blank line separator") {
            let log = BrewManager.buildCheckLog(updateOutput: "Updated 1 tap.", outdatedOutput: "wget (1.0) < 2.0")
            try expectTrue(log.contains("Updated 1 tap."))
            try expectTrue(log.contains("wget (1.0) < 2.0"))
            try expectTrue(log.contains("\n\n"))
        }

        it("trims whitespace from outputs") {
            let log = BrewManager.buildCheckLog(updateOutput: "  \n  ", outdatedOutput: "  \n  ")
            try expect(log, "")
        }
    }

    describe("BrewManager.outputContainsError") {
        it("detects Error: pattern") {
            try expectTrue(BrewManager.outputContainsError("Error: docker-desktop: Failure while executing"))
        }

        it("detects sudo password required") {
            try expectTrue(BrewManager.outputContainsError("sudo: a password is required"))
        }

        it("returns false for clean output") {
            try expectFalse(BrewManager.outputContainsError("==> Upgrading wget\n🍺  1.24.5"))
        }

        it("returns false for empty output") {
            try expectFalse(BrewManager.outputContainsError(""))
        }
    }
}

// MARK: - Main

@main
struct TestMain {
    static func main() {
        TestRunner.main()
    }
}
