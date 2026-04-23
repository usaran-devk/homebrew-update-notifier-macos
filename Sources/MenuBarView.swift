import SwiftUI

/// The main popover view shown when clicking the menu bar icon.
///
/// Displays the current status, a list of outdated packages with checkboxes,
/// and controls for updating, checking, and accessing settings.
/// After an update, shows collapsible per-package results with status and log.
@MainActor
struct MenuBarView: View {
    @ObservedObject var brewManager: BrewManager
    let onSettings: () -> Void
    let onQuit: () -> Void
    @State private var rotateIcon = false

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.UI.contentPadding) {
            // App title
            Text(Constants.appName)
                .font(.title3)
                .fontWeight(.bold)

            Divider()

            // Status header
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if brewManager.state == .updating {
                        IndeterminateRing(color: brewManager.state.statusColor, size: 14, lineWidth: 2)
                    } else {
                        Image(systemName: brewManager.state.badgeSymbolName)
                            .foregroundColor(brewManager.state.statusColor)
                            // Rotate while checking
                            .rotationEffect(.degrees(rotateIcon ? 360 : 0))
                            .animation(rotateIcon ? Animation.linear(duration: 1.0).repeatForever(autoreverses: false) : .default, value: rotateIcon)
                    }
                    Text(brewManager.state.statusText)
                        .font(.headline)
                    Spacer()
                }
                if case .error(let message) = brewManager.state {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .onAppear {
                rotateIcon = (brewManager.state == .checking)
            }
            .onChange(of: brewManager.state) { old, new in
                let should = (new == .checking)
                // Start/stop rotation
                rotateIcon = should
            }
            .padding(.bottom, 4)

            // Collapsible check log (shown after a manual or automatic check)
            if !brewManager.checkLog.isEmpty && brewManager.state != .checking && brewManager.state != .updating {
                CheckLogRow(log: brewManager.checkLog)
            }

            Divider()

            // Update results (shown during/after update)
            if !brewManager.updateResults.isEmpty && (brewManager.state == .updating || brewManager.state.isUpdateComplete) {
                updateResultsView
            }
            // Package list (shown when updates are available and not updating)
            else if brewManager.packages.isEmpty && brewManager.state == .upToDate {
                Text(L10n.Menu.noUpdates)
                    .foregroundColor(.secondary)
            } else if !brewManager.packages.isEmpty {
                packageSelectionView
            }

            Divider()

            // Bottom controls
            HStack {
                Button(L10n.Menu.checkNow) {
                    Task { await brewManager.checkForUpdates() }
                }
                .disabled(brewManager.state == .checking || brewManager.state == .updating)

                Spacer()

                Button(L10n.Menu.settings) {
                    onSettings()
                }

                Button(L10n.Menu.quit) {
                    onQuit()
                }
            }
        }
        .padding(Constants.UI.contentPadding)
        .frame(width: Constants.UI.popoverWidth)
    }

    // MARK: - Package Selection View

    /// Ordered list of unique package types present in the current package list.
    private var packageTypes: [String] {
        var seen = Set<String>()
        return brewManager.packages.compactMap { pkg in
            seen.insert(pkg.type).inserted ? pkg.type : nil
        }
    }

    /// Ordered list of unique package types present in update results.
    private var updateResultTypes: [String] {
        var seen = Set<String>()
        return brewManager.updateResults.compactMap { result in
            seen.insert(result.package.type).inserted ? result.package.type : nil
        }
    }

    /// Shows the list of outdated packages grouped by type, each group with a
    /// SelectAll toggle, plus a global SelectAll toggle at the top.
    private var packageSelectionView: some View {
        VStack(alignment: .leading, spacing: Constants.UI.contentPadding) {
            // Global select-all toggle
            Toggle(isOn: Binding(
                get: { brewManager.allSelected },
                set: { brewManager.setAllSelected($0) }
            )) {
                Text(brewManager.allSelected ? L10n.Menu.deselectAll : L10n.Menu.selectAll)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .toggleStyle(.checkbox)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(packageTypes, id: \.self) { type in
                        let typePackages = brewManager.packages.filter { $0.type == type }
                        VStack(alignment: .leading, spacing: 4) {
                            // Group header with type label and per-group select-all toggle
                            HStack {
                                Text(L10n.Menu.packageTypeName(type))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                Spacer()
                                Toggle(isOn: Binding(
                                    get: { brewManager.allSelected(forType: type) },
                                    set: { brewManager.setAllSelected($0, forType: type) }
                                )) {
                                    Text(brewManager.allSelected(forType: type) ? L10n.Menu.deselectAll : L10n.Menu.selectAll)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .toggleStyle(.checkbox)
                            }

                            // Packages in this group
                            ForEach(typePackages) { pkg in
                                Toggle(isOn: Binding(
                                    get: { brewManager.selectedPackages.contains(pkg.name) },
                                    set: { _ in brewManager.toggleSelection(pkg.name) }
                                )) {
                                    HStack {
                                        Text(pkg.name)
                                            .font(.body)
                                        Spacer()
                                        Text("\(pkg.installedVersion) → \(pkg.availableVersion)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .padding(.leading, 8)
                            }
                        }

                        if type != packageTypes.last {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 250)

            // Update button
            Button(action: {
                Task { await brewManager.updateSelectedPackages() }
            }) {
                Text(L10n.Menu.updateSelected)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(brewManager.selectedPackages.isEmpty || brewManager.state == .updating)
        }
    }

    // MARK: - Update Results View

    /// Shows per-package update results with collapsible log sections.
    private var updateResultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(updateResultTypes, id: \.self) { type in
                    let typeResults = brewManager.updateResults.filter { $0.package.type == type }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Menu.packageTypeName(type))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        ForEach(typeResults) { result in
                            PackageResultRow(result: result)
                        }
                    }

                    if type != updateResultTypes.last {
                        Divider()
                    }
                }
            }
        }
        .frame(maxHeight: 300)
    }
}

// MARK: - Package Result Row

/// A single collapsible row showing a package's update status and log.
@MainActor
struct PackageResultRow: View {
    let result: PackageUpdateResult
    @State private var isExpanded: Bool

    init(result: PackageUpdateResult) {
        self.result = result
        // Auto-expand only on failure; do not auto-expand while updating so the
        // user has to opt in to view the streaming output.
        _isExpanded = State(initialValue: result.status == .failed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row — tappable to toggle expansion
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 10)

                Text(result.package.name)
                    .font(.body)
                    .fontWeight(.medium)

                Text("\(result.package.installedVersion) → \(result.package.availableVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if result.status == .updating {
                    // Small indeterminate ring for per-package updating state
                    IndeterminateRing(color: result.status.color, size: 11, lineWidth: 2)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: result.status.symbolName)
                        .foregroundColor(result.status.color)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
            .padding(.vertical, 4)

            // Expandable log section
            if isExpanded && !result.log.isEmpty {
                Text(result.log)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Check Log Row

/// A collapsible row showing the summary log from the last check operation.
@MainActor
struct CheckLogRow: View {
    let log: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 10)

                Text(L10n.Log.checkDetails)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
            .padding(.vertical, 2)

            if isExpanded {
                Text(log)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
            }
        }
    }
}
