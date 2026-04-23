import Foundation

/// Parses and analyzes output from `brew` commands.
///
/// All methods are pure functions (`nonisolated static`) with no side effects,
/// making them easy to test in isolation.
enum BrewParser {

    // MARK: - JSON Parsing

    /// Parses the JSON output of `brew outdated --json=v2`.
    /// - Parameter json: The raw JSON string.
    /// - Returns: An array of `BrewPackage` with update info.
    static func parseOutdatedJSON(_ json: String) -> [BrewPackage] {
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

    // MARK: - Log Building

    /// Builds the check log from raw `brew update` and `brew outdated` output.
    /// - Parameters:
    ///   - updateOutput: Raw output from `brew update`.
    ///   - outdatedOutput: Raw output from `brew outdated` (plain text).
    /// - Returns: A combined log string.
    static func buildCheckLog(updateOutput: String = "", outdatedOutput: String = "") -> String {
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

    // MARK: - Error Detection

    /// Checks whether process output contains error patterns from brew.
    ///
    /// Homebrew sometimes exits with code 0 even when individual package
    /// upgrades fail. This method scans the output for known error markers.
    /// - Parameter output: The process output string.
    /// - Returns: `true` if the output contains error indicators.
    static func outputContainsError(_ output: String) -> Bool {
        output.contains("Error:") || output.contains("sudo: a password is required")
    }

    /// Extracts the most useful first error line from brew process output.
    /// - Parameter output: The raw process output.
    /// - Returns: The first known error line if present.
    static func firstErrorLine(in output: String) -> String? {
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let errorLine = lines.first(where: { $0.contains("Error:") }) {
            return errorLine
        }
        if let sudoLine = lines.first(where: { $0.contains("sudo: a password is required") }) {
            return sudoLine
        }
        return nil
    }
}
