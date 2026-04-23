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
    @State private var expandedDependencyTypes: Set<String> = []
    @State private var showingUpdateModeDialog = false

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.UI.contentPadding) {
            // App title
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: Constants.Symbols.base)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.appName)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(L10n.appNameShortDescription)
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("v\(Bundle.main.appVersionString)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Divider()

            // Status header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if brewManager.state == .updating || brewManager.state == .checking {
                        IndeterminateRing(color: brewManager.state.statusColor, size: 14, lineWidth: 2)
                    } else {
                        Image(systemName: brewManager.state.badgeSymbolName)
                            .foregroundColor(brewManager.state.statusColor)
                    }
                    Text(brewManager.state.statusText)
                        .font(.headline)
                    Spacer()
                }
                if case .checkError(let message) = brewManager.state {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                } else if case .error(let message) = brewManager.state {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(.bottom, 4)

            // Collapsible check log (shown after a manual or automatic check)
            if !brewManager.checkLog.isEmpty && brewManager.state != .checking && brewManager.state != .updating {
                CheckLogRow(log: brewManager.checkLog, lastChecked: brewManager.checkTime)
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
            } else if !brewManager.packages.isEmpty && brewManager.state == .updatesAvailable {
                packageSelectionView
            }

            Divider()

            // Bottom controls
            HStack {
                if brewManager.canShowRemainingPackagesAfterUpdate {
                    Button(L10n.Menu.showRemaining) {
                        brewManager.showRemainingPackagesAfterUpdate()
                    }
                    .disabled(brewManager.state == .checking || brewManager.state == .updating)
                }

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
        .confirmationDialog(
            L10n.Menu.updateModePromptTitle,
            isPresented: $showingUpdateModeDialog,
            titleVisibility: .visible
        ) {
            Button(L10n.Menu.updateSelected) {
                Task { await brewManager.updateSelectedPackages(forceUpgrade: false) }
            }
            Button(L10n.Menu.updateSelectedWithForce) {
                Task { await brewManager.updateSelectedPackages(forceUpgrade: true) }
            }
            Button(L10n.Settings.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Menu.updateModePromptMessage)
        }
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

    /// Selected package dependency trees grouped by package type.
    private var selectedDependencyTreeSections: [(type: String, roots: [DependencyTreeNode])] {
        var result: [(type: String, roots: [DependencyTreeNode])] = []
        for type in packageTypes {
            let typePackages = brewManager.packages.filter {
                $0.type == type && brewManager.selectedPackages.contains($0.name)
            }
            if typePackages.isEmpty {
                continue
            }
            let roots = buildDependencyTreeNodes(for: typePackages)
            if !roots.isEmpty {
                result.append((type, roots))
            }
        }

        return result
    }

    /// Selected package names that participate in dependency cycles.
    private var selectedDependencyCycleNodes: [String] {
        brewManager.selectedDependencyCycleNodes
    }

    /// Builds a dependency tree for the given selected packages.
    private func buildDependencyTreeNodes(for packages: [BrewPackage]) -> [DependencyTreeNode] {
        let orderedNames = packages.map(\.name)
        let packageByName = Dictionary(uniqueKeysWithValues: packages.map { ($0.name, $0) })
        let packageNames = Set(orderedNames)
        let baseOrder = Dictionary(uniqueKeysWithValues: brewManager.packages.enumerated().map { ($1.name, $0) })

        func stableCompare(_ lhs: String, _ rhs: String) -> Bool {
            let li = baseOrder[lhs] ?? Int.max
            let ri = baseOrder[rhs] ?? Int.max
            if li != ri { return li < ri }
            return lhs < rhs
        }

        var childrenByNode: [String: [String]] = [:]
        for name in orderedNames {
            let deps = (brewManager.dependencyGraph[name] ?? [])
                .filter { packageNames.contains($0) }
                .sorted(by: stableCompare)
            childrenByNode[name] = deps
        }

        let dependedUpon = Set(childrenByNode.values.flatMap { $0 })
        var roots = orderedNames.filter { !dependedUpon.contains($0) }.sorted(by: stableCompare)
        if roots.isEmpty {
            roots = orderedNames.sorted(by: stableCompare)
        }

        func makeNode(_ name: String, path: Set<String>) -> DependencyTreeNode? {
            guard let pkg = packageByName[name] else { return nil }
            if path.contains(name) {
                return DependencyTreeNode(package: pkg, children: [])
            }

            let nextPath = path.union([name])
            let children = (childrenByNode[name] ?? []).compactMap { makeNode($0, path: nextPath) }
            return DependencyTreeNode(package: pkg, children: children)
        }

        var built = Set<String>()
        var nodes: [DependencyTreeNode] = []
        for root in roots {
            guard !built.contains(root), let node = makeNode(root, path: []) else { continue }
            built.insert(root)
            nodes.append(node)
        }
        for name in orderedNames.sorted(by: stableCompare) where !built.contains(name) {
            guard let node = makeNode(name, path: []) else { continue }
            built.insert(name)
            nodes.append(node)
        }

        return nodes
    }

    /// Shows the list of outdated packages grouped by type, each group with a
    /// SelectAll toggle, plus a global SelectAll toggle at the top.
    private var packageSelectionView: some View {
        VStack(alignment: .leading, spacing: Constants.UI.contentPadding) {
/*
            // Disable dependency tree view for now
            if !selectedDependencyTreeSections.isEmpty {
                dependencyTreeView
            }
*/
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
            .frame(maxHeight: Constants.UI.popoverHeight - 60) // Leave space for the Update button at the bottom

            // Update button
            Button(action: {
                showingUpdateModeDialog = true
            }) {
                Text(L10n.Menu.updateSelected)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(brewManager.selectedPackages.isEmpty || brewManager.state == .updating)
        }
        .frame(maxHeight: Constants.UI.popoverHeight - 60) // Leave space for the Update button at the bottom
    }

    // MARK: - Dependency Tree View

    /// Shows the dependency tree for the currently selected packages, grouped by type.
    private var dependencyTreeView: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(selectedDependencyTreeSections, id: \.type) { section in
                    let isExpanded = expandedDependencyTypes.contains(section.type)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: 10)

                            Text(L10n.Menu.dependencyTreeForType(L10n.Menu.packageTypeName(section.type)))
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isExpanded {
                                    expandedDependencyTypes.remove(section.type)
                                } else {
                                    expandedDependencyTypes.insert(section.type)
                                }
                            }
                        }
                        .padding(.vertical, 2)

                        if isExpanded {
                            ScrollView(.vertical) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(section.roots.indices), id: \.self) { index in
                                        let root = section.roots[index]
                                        DependencyTreeNodeRows(
                                            node: root,
                                            ancestorContinuations: [],
                                            isLast: index == section.roots.count - 1,
                                            isRoot: true
                                        )
                                    }
                                }
                                .frame(maxWidth: Constants.UI.popoverWidth - (2 * Constants.UI.contentPadding) - 32, alignment: .leading)
                                .padding(8)
                            }
                            .frame(maxHeight: Constants.UI.popoverHeight)
                            .padding(.leading, 16)
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !selectedDependencyCycleNodes.isEmpty {
                    Text(L10n.Menu.dependencyCycleWarning(selectedDependencyCycleNodes.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
            .padding(.trailing, 12)
        }
        .frame(maxHeight: Constants.UI.popoverHeight - 60) // Leave space for the Update button at the bottom
    }
}

private struct DependencyTreeNode: Identifiable {
    let package: BrewPackage
    let children: [DependencyTreeNode]

    var id: String { package.id }
}

@MainActor
private struct DependencyTreeNodeRows: View {
    let node: DependencyTreeNode
    let ancestorContinuations: [Bool]
    let isLast: Bool
    let isRoot: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Array(ancestorContinuations.indices), id: \.self) { index in
                    let hasContinuation = ancestorContinuations[index]
                    Rectangle()
                        .fill(hasContinuation ? Color.secondary.opacity(0.25) : Color.clear)
                        .frame(width: 1, height: 14)
                        .frame(width: 10)
                }

                if !isRoot {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(!isLast ? Color.secondary.opacity(0.25) : Color.clear)
                            .frame(width: 1, height: 14)

                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 9, height: 1)
                    }
                    .frame(width: 10, height: 14)
                }

                Image(systemName: node.package.type == Constants.PackageType.cask ? "app.fill" : "shippingbox.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(node.package.name)
                    .font(.caption)

                Spacer(minLength: 4)

                Text("\(node.package.installedVersion) → \(node.package.availableVersion)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)

            ForEach(Array(node.children.indices), id: \.self) { index in
                let child = node.children[index]
                DependencyTreeNodeRows(
                    node: child,
                    ancestorContinuations: ancestorContinuations + [!isLast],
                    isLast: index == node.children.count - 1,
                    isRoot: false
                )
            }
        }
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
                    .lineLimit(nil)
                    .frame(maxWidth: Constants.UI.popoverWidth - (2 * Constants.UI.contentPadding) - 32, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .padding(.leading, 8)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxHeight: Constants.UI.popoverHeight - 60) // Leave space for the Update button at the bottom
    }
}

// MARK: - Check Log Row

/// A collapsible row showing the summary log from the last check operation.
@MainActor
struct CheckLogRow: View {
    let log: String
    let lastChecked: Date?
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
    
                // Display last check time if available
                if let lastChecked = lastChecked {
                    Text(
                        L10n.Log.lastChecked +
                            lastChecked.formatted(
                                .dateTime
                                    .year()
                                    .month()
                                    .day()
                                    .hour(.twoDigits(amPM: .omitted))
                                    .minute(.twoDigits)
                                    .second(.twoDigits)
                                    .timeZone()
                            )
                    )
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
            .padding(.vertical, 2)

            if isExpanded {
                ScrollView(.vertical) {
                    Text(log)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                        .frame(maxWidth: Constants.UI.popoverWidth - (2 * Constants.UI.contentPadding) - 32, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .padding(.leading, 16)
                .padding(.vertical, 4)
            }
        }
        .frame(maxHeight: isExpanded ? Constants.UI.popoverHeight - 60 : nil)
    }
}

