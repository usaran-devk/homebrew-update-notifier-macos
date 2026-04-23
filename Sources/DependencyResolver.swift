import Foundation

/// Resolves and analyses dependency graphs over `BrewPackage` collections.
///
/// All methods are pure functions (`nonisolated static`) with no side effects,
/// making them easy to test in isolation.
enum DependencyResolver {

    // MARK: - Selection Expansion

    /// Expands a set of selected package names to include all transitive dependencies.
    ///
    /// The returned set always contains the originally selected names.
    /// Cycles are handled safely using a visited set.
    /// - Parameters:
    ///   - selectedNames: Initially selected package names.
    ///   - dependencyGraph: Direct dependencies between outdated packages.
    /// - Returns: Selected names including all reachable dependencies.
    static func expandedSelectionIncludingDependencies(
        selectedNames: Set<String>,
        dependencyGraph: [String: [String]]
    ) -> Set<String> {
        var expanded = selectedNames
        var stack = Array(selectedNames)

        while let current = stack.popLast() {
            for dep in dependencyGraph[current] ?? [] {
                if expanded.insert(dep).inserted {
                    stack.append(dep)
                }
            }
        }

        return expanded
    }

    /// Removes deselected packages and all selected dependents that require them.
    ///
    /// This performs a reverse-graph traversal so that deselecting a dependency
    /// also deselects every selected package that (directly or transitively)
    /// depends on it.
    /// - Parameters:
    ///   - selectedNames: Current selected package names.
    ///   - deselectedNames: Package names explicitly deselected by the user.
    ///   - dependencyGraph: Direct dependencies between outdated packages.
    /// - Returns: Updated selection after cascading dependent removals.
    static func selectionAfterDeselectionRemovingDependents(
        selectedNames: Set<String>,
        deselectedNames: Set<String>,
        dependencyGraph: [String: [String]]
    ) -> Set<String> {
        var reverseGraph: [String: Set<String>] = [:]
        for (pkg, deps) in dependencyGraph {
            for dep in deps {
                reverseGraph[dep, default: []].insert(pkg)
            }
        }

        var toRemove = deselectedNames.intersection(selectedNames)
        var stack = Array(toRemove)

        while let current = stack.popLast() {
            for dependent in reverseGraph[current] ?? [] where selectedNames.contains(dependent) {
                if toRemove.insert(dependent).inserted {
                    stack.append(dependent)
                }
            }
        }

        return selectedNames.subtracting(toRemove)
    }

    // MARK: - Update Ordering

    /// Orders packages so each dependency appears before its dependents.
    ///
    /// Uses a depth-first topological sort. If cycles exist, remaining packages
    /// are appended in alphabetical order.
    /// - Parameters:
    ///   - packages: The packages to order.
    ///   - dependencyGraph: Direct dependencies between outdated packages (name → direct deps).
    /// - Returns: The packages sorted so dependencies precede dependents.
    static func orderPackagesForUpdate(
        _ packages: [BrewPackage],
        dependencyGraph: [String: [String]]
    ) -> [BrewPackage] {
        let packageByName = Dictionary(uniqueKeysWithValues: packages.map { ($0.name, $0) })
        let packageNames = Set(packageByName.keys)

        var orderedNames: [String] = []
        var permanent = Set<String>()
        var temporary = Set<String>()

        func visit(_ name: String) {
            guard packageNames.contains(name) else { return }
            if permanent.contains(name) { return }
            if temporary.contains(name) { return }

            temporary.insert(name)
            let deps = (dependencyGraph[name] ?? []).filter { packageNames.contains($0) }
            for dep in deps {
                visit(dep)
            }
            temporary.remove(name)
            permanent.insert(name)
            orderedNames.append(name)
        }

        for package in packages {
            visit(package.name)
        }

        if orderedNames.count < packages.count {
            let missing = packageNames.subtracting(orderedNames)
            orderedNames.append(contentsOf: missing.sorted())
        }

        return orderedNames.compactMap { packageByName[$0] }
    }

    // MARK: - Tree Rendering

    /// Builds ASCII tree lines for a dependency graph over the given package order.
    /// - Parameters:
    ///   - orderedPackages: Packages in topological order.
    ///   - dependencyGraph: Direct dependencies between outdated packages.
    /// - Returns: Lines of an ASCII dependency tree.
    static func dependencyTreeLines(
        orderedPackages: [BrewPackage],
        dependencyGraph: [String: [String]]
    ) -> [String] {
        let orderedNames = orderedPackages.map(\.name)
        let packageNames = Set(orderedNames)
        var childrenByNode: [String: [String]] = [:]

        for name in orderedNames {
            let deps = (dependencyGraph[name] ?? []).filter { packageNames.contains($0) }
            childrenByNode[name] = deps
        }

        let dependedUpon = Set(childrenByNode.values.flatMap { $0 })
        let roots = orderedNames.filter { !dependedUpon.contains($0) }

        var visited = Set<String>()
        var lines: [String] = []

        func walk(_ name: String, prefix: String, isLast: Bool, isRoot: Bool) {
            guard !visited.contains(name) else { return }
            visited.insert(name)

            if isRoot {
                lines.append(name)
            } else {
                lines.append("\(prefix)\(isLast ? "`- " : "|- ")\(name)")
            }

            let children = childrenByNode[name] ?? []
            for (idx, child) in children.enumerated() {
                let nextPrefix = isRoot
                    ? ""
                    : prefix + (isLast ? "   " : "|  ")
                walk(child, prefix: nextPrefix, isLast: idx == children.count - 1, isRoot: false)
            }
        }

        for (idx, root) in roots.enumerated() {
            walk(root, prefix: "", isLast: idx == roots.count - 1, isRoot: true)
        }

        for name in orderedNames where !visited.contains(name) {
            walk(name, prefix: "", isLast: true, isRoot: true)
        }

        return lines
    }

    // MARK: - Cycle Detection

    /// Returns package names that participate in at least one dependency cycle.
    /// - Parameters:
    ///   - packages: The packages to inspect.
    ///   - dependencyGraph: Direct dependencies between outdated packages.
    /// - Returns: Sorted list of names that are part of any detected cycle.
    static func dependencyCycleNodes(
        packages: [BrewPackage],
        dependencyGraph: [String: [String]]
    ) -> [String] {
        let packageNames = Set(packages.map(\.name))
        var state: [String: Int] = [:] // 0: unvisited, 1: visiting, 2: done
        var stack: [String] = []
        var cycleNodes = Set<String>()

        func dfs(_ name: String) {
            state[name] = 1
            stack.append(name)

            let deps = (dependencyGraph[name] ?? []).filter { packageNames.contains($0) }
            for dep in deps {
                let depState = state[dep] ?? 0
                if depState == 0 {
                    dfs(dep)
                } else if depState == 1 {
                    if let start = stack.lastIndex(of: dep) {
                        for node in stack[start...] {
                            cycleNodes.insert(node)
                        }
                    }
                }
            }

            _ = stack.popLast()
            state[name] = 2
        }

        for name in packages.map(\.name) where (state[name] ?? 0) == 0 {
            dfs(name)
        }

        return cycleNodes.sorted()
    }
}
