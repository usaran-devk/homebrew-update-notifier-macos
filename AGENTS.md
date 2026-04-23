# Agent Instructions for Homebrew Update Notifier

## Build/Test/Lint Commands

**Build the app:**
```bash
make all
```

**Run the app:**
```bash
make run
```

**Run all tests:**
```bash
make test
```

**Run specific test suite:**
Edit `Tests/Tests.swift` and comment out the `test*()` function calls in `TestRunner.main()`, leaving only the one you want. Then:
```bash
make test
```
Available test suites: Constants, Localization, UpdateState, Settings, BrewManagerParsing

**Verify build compiles:**
```bash
make all
```
(Builds the app bundle to `.build/Homebrew Update Notifier.app`)

**Clean build artifacts:**
```bash
make clean
```

**Full installation (build + copy to /Applications):**
```bash
make install
```

**Uninstall:**
```bash
make uninstall
```

**Swift version:** 6 with `-O` optimization flag

## Code Style Guidelines

### Imports
- Use alphabetical order within categories (Foundation first, then AppKit/SwiftUI)
- Group related imports: standard library, then framework/library imports

### Naming Conventions
- **Types (classes, structs, enums):** PascalCase (e.g., `BrewManager`, `UpdateState`)
- **Functions/properties/variables:** camelCase (e.g., `checkForUpdates`, `checkIntervalMinutes`)
- **Constants:** camelCase in groups, or PascalCase for enum cases (e.g., `Constants.Executables.brewARM`, `case .disconnected`)
- **Private properties:** prefix with underscore or mark `private`
- **Published properties (SwiftUI):** use `@Published` for observable state
- **Main Actor:** mark view controllers with `@MainActor` for UI thread safety

### Formatting & Structure
- **Line length:** No strict limit, but keep reasonable for readability
- **Indentation:** 4 spaces (not tabs)
- **Access modifiers:** Explicit (e.g., `private(set)`, `final` for classes)
- **MARK comments:** Use `// MARK: -` to organize sections within files
- **Blank lines:** One between methods, sections marked with MARK

### Documentation & Comments
- **Public APIs:** Document with `///` doc comments explaining purpose, parameters, returns, and edge cases
- **Complex logic:** Add inline comments explaining "why," not just "what"
- **Doc comment format:**
  ```swift
  /// Brief description.
  ///
  /// Longer explanation if needed.
  /// - Parameters:
  ///   - param1: Description.
  /// - Returns: Description.
  ```

### Types & Errors
- **Use optionals sparingly:** Prefer `Result<T, Error>` or explicit error states for failures
- **Equatable/Sendable:** Apply to types that need comparison or thread safety
- **Associated values in enums:** Use for context (e.g., `case error(String)`)
- **Error handling:** Throw `Error` types or use `Result`; avoid silent failures
- **Error types:** Define custom `Error` enums for specific error cases; log all errors before throwing

### Concurrency & Thread Safety
- **MainActor:** Mark SwiftUI views and view models with `@MainActor` for UI thread safety
- **Sendable:** Apply `Sendable` to types passed between threads (e.g., error states, process output)
- **Avoid data races:** Use `nonisolated(unsafe)` only for test globals; document the reason

### Constants & Magic Numbers
- **Centralize:** All hard-coded strings and numbers in `Sources/Constants.swift`
- **Organize by category:** Use nested enums (e.g., `Constants.Executables`, `Constants.Symbols`)
- **Document:** Add comments explaining purpose and usage

### Testing
- **Use custom test framework:** `Tests/Tests.swift` provides `describe()`, `it()`, and expectations
- **Testable sources:** Listed in Makefile `TESTABLE_SOURCES` (currently: Constants, Localization, UpdateState, Settings, BrewManager)
- **Exclude from tests:** UI files (MenuBarView, SettingsView, AppDelegate) and `main.swift` entry point
- **Expectations:** Use `expect()`, `expectTrue()`, `expectFalse()`, `expectNil()`, `expectNotNil()`
- **No interactive tests:** Avoid password prompts; mock/inject dependencies instead
- **Test isolation:** Each test should be independent; clean up shared state (e.g., UserDefaults) manually after each test

### i18n & Localization
- **Never hardcode user-facing strings:** Always use `L10n.*` keys (e.g., `L10n.State.upToDate`)
- **Provide German translations:** See `Sources/Localization.swift` for keys and translations
- **Organize keys:** Group by feature/context (e.g., `L10n.State.*`, `L10n.Error.*`, `L10n.Log.*`)

### Git Commits

1. Keep git commit messages short but meaningful

## Key Guidelines

1. Maintain a `./.gitignore` file
2. Maintain a `./README.md` file with a brief project overview
3. Maintain existing code structure and organisation.
4. Write unit tests for new functionality.
5. Use i18n and provide translations for German.
6. Document public APIs and complex logic.
7. Provide documentation about how to compile, install, uninstall and use the program.
8. Suggest changes to the `docs/` folder when appropriate.
9. Follow software principles such as DRY and YAGNI.
10. Keep diffs as minimal as possible.
11. Avoid interactive actions in tests (e.g., password entries for privilege escalation).
12. Avoid hardcoded strings; always use constants clustered in `Constants.swift`.
