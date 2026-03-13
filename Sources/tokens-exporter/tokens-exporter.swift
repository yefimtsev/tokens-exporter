import ArgumentParser
import Foundation

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case yaml
    case md
}

@main
struct TokensExporter: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tokens-exporter",
        abstract: "Export Figma design tokens to compact LLM-friendly formats."
    )

    @Argument(help: "Paths to .tokens.json files.")
    var files: [String]

    @Option(name: .shortAndLong, help: "Categories to export (repeatable). Use --list to see available.")
    var category: [String] = []

    @Flag(help: "List available categories and their token counts.")
    var list: Bool = false

    @Flag(help: "Export all categories.")
    var all: Bool = false

    @Option(name: .shortAndLong, help: "Output format: yaml (default) or md.")
    var format: OutputFormat = .yaml

    @Flag(help: "Auto-detect and strip fields that are constant across all tokens.")
    var compact: Bool = false

    @Option(name: .shortAndLong, help: "Write output to file instead of stdout.")
    var output: String?

    mutating func run() throws {
        var themes: [(name: String, root: [String: Any])] = []
        for filePath in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Invalid JSON in \(filePath)")
            }
            let tokenRoot = extractTokenRoot(json)
            let themeName = deriveThemeName(from: filePath)
            themes.append((name: themeName, root: tokenRoot))
        }

        if list {
            printCategoryList(themes[0].root)
            return
        }

        let selectedKeys = try resolveCategories(from: themes[0].root)

        let result: String
        if themes.count == 1 {
            result = formatTheme(themes[0].root, selectedKeys: selectedKeys)
        } else {
            var parts: [String] = []
            for theme in themes {
                let inner = formatTheme(theme.root, selectedKeys: selectedKeys)
                switch format {
                case .yaml:
                    parts.append("\(theme.name):")
                    for line in inner.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false) {
                        parts.append("  \(line)")
                    }
                case .md:
                    parts.append("# \(theme.name)\n")
                    parts.append(inner)
                }
            }
            result = parts.joined(separator: "\n") + "\n"
        }

        if let outputPath = output {
            try result.write(toFile: outputPath, atomically: true, encoding: .utf8)
        } else {
            print(result, terminator: "")
        }
    }

    // MARK: - Multi-file helpers

    private func extractTokenRoot(_ json: [String: Any]) -> [String: Any] {
        let contentKeys = json.keys.filter { !$0.hasPrefix("$") }
        if contentKeys.count == 1, let single = json[contentKeys[0]] as? [String: Any] {
            return single
        }
        return json.filter { !$0.key.hasPrefix("$") }
    }

    private func deriveThemeName(from path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
            .replacingOccurrences(of: ".tokens.json", with: "")
            .replacingOccurrences(of: ".json", with: "")
            .lowercased()
    }

    private func resolveCategories(from tokenRoot: [String: Any]) throws -> [String] {
        if all {
            return tokenRoot.keys.sorted()
        } else if !category.isEmpty {
            for cat in category {
                guard tokenRoot[cat] != nil else {
                    throw ValidationError("Unknown category '\(cat)'. Use --list to see available categories.")
                }
            }
            return category
        } else {
            throw ValidationError("Specify categories with -c/--category, or use --all. Use --list to see available.")
        }
    }

    private func formatTheme(_ tokenRoot: [String: Any], selectedKeys: [String]) -> String {
        var selected: [String: Any] = [:]
        for key in selectedKeys {
            selected[key] = tokenRoot[key]
        }

        var strippedHeader = ""
        if compact {
            let leafValues = collectLeafValues(selected)
            let constants = leafValues.filter { $0.value.count == 1 }
            if !constants.isEmpty {
                let constantKeys = constants.keys.sorted()
                let stripped = constantKeys.map { key in
                    "\(key)=\(constants[key]!.first!)"
                }
                selected = stripFields(selected, fields: Set(constantKeys))

                switch format {
                case .yaml:
                    strippedHeader = "# Stripped (constant): \(stripped.joined(separator: ", "))\n"
                case .md:
                    strippedHeader = "> Stripped (constant): \(stripped.joined(separator: ", "))\n\n"
                }
            }
        }

        switch format {
        case .yaml:
            return strippedHeader + emitYAML(selected, sortedKeys: selectedKeys)
        case .md:
            return strippedHeader + emitMarkdown(selected, sortedKeys: selectedKeys)
        }
    }

    // MARK: - List

    private func printCategoryList(_ root: [String: Any]) {
        let categories = root.keys.sorted()
        let counts = categories.map { (key: $0, count: countTokens(root[$0]!)) }
        let maxLen = counts.map(\.key.count).max() ?? 0

        print("Available categories:\n")
        for item in counts {
            let padded = item.key.padding(toLength: maxLen + 2, withPad: " ", startingAt: 0)
            print("  \(padded)\(item.count) tokens")
        }
        print("\nTotal: \(counts.map(\.count).reduce(0, +)) tokens")
    }

    private func countTokens(_ value: Any) -> Int {
        guard let dict = value as? [String: Any] else { return 0 }
        if isTokenLeaf(dict) { return 1 }
        return dict.values.map { countTokens($0) }.reduce(0, +)
    }

    // MARK: - Token leaf detection

    private func isTokenLeaf(_ dict: [String: Any]) -> Bool {
        dict["$type"] != nil && dict["$value"] != nil
    }

    // MARK: - Compact mode

    /// Collect all leaf token values grouped by property name.
    /// Returns [propertyName: Set of distinct stringified values].
    private func collectLeafValues(_ value: Any) -> [String: Set<String>] {
        guard let dict = value as? [String: Any] else { return [:] }

        if isTokenLeaf(dict) {
            // This is a single leaf — not a property group, skip
            return [:]
        }

        // Check if all non-$ children are token leaves → this is a property group
        let childKeys = dict.keys.filter { !$0.hasPrefix("$") }
        let allLeaves = !childKeys.isEmpty && childKeys.allSatisfy {
            isTokenLeaf(dict[$0] as? [String: Any] ?? [:])
        }

        if allLeaves {
            var result: [String: Set<String>] = [:]
            for key in childKeys {
                let leaf = dict[key] as! [String: Any]
                let stringVal = stringifyValue(leaf["$value"]!)
                result[key, default: []].insert(stringVal)
            }
            return result
        }

        // Recurse into children
        var result: [String: Set<String>] = [:]
        for (_, val) in dict where !(val is String) {
            let child = collectLeafValues(val)
            for (k, v) in child {
                result[k, default: []].formUnion(v)
            }
        }
        return result
    }

    /// Strip token leaves with the given property names from the tree.
    private func stripFields(_ value: Any, fields: Set<String>) -> [String: Any] {
        guard let dict = value as? [String: Any] else { return [:] }

        var result: [String: Any] = [:]
        for (key, val) in dict {
            guard !key.hasPrefix("$") || key == "$type" || key == "$value" || key == "$description" || key == "$extensions" else {
                result[key] = val
                continue
            }

            if let childDict = val as? [String: Any] {
                if isTokenLeaf(childDict) {
                    // This is a leaf — skip if its key is in the strip set
                    if fields.contains(key) { continue }
                    result[key] = val
                } else {
                    // Recurse
                    let stripped = stripFields(val, fields: fields)
                    if !stripped.isEmpty {
                        result[key] = stripped
                    }
                }
            } else {
                result[key] = val
            }
        }
        return result
    }

    private func stringifyValue(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(n) {
                return n.boolValue ? "true" : "false"
            }
            if n.doubleValue == Double(n.intValue) && !n.stringValue.contains(".") {
                return "\(n.intValue)"
            }
            return "\(n)"
        default:
            return "\(value)"
        }
    }

    // MARK: - Clean tree

    /// Recursively strips $extensions and $type, flattens $value leaves into plain values.
    /// Returns a cleaned structure suitable for output.
    private func cleanTree(_ value: Any) -> Any {
        guard let dict = value as? [String: Any] else { return value }

        if isTokenLeaf(dict) {
            return flattenValue(dict["$value"]!)
        }

        var result: [(key: String, value: Any)] = []
        for key in dict.keys.sorted() where !key.hasPrefix("$") {
            result.append((key: key, value: cleanTree(dict[key]!)))
        }
        return OrderedDict(entries: result)
    }

    /// Flatten complex $value objects (e.g. color dicts) into simple scalars.
    private func flattenValue(_ value: Any) -> Any {
        guard let dict = value as? [String: Any] else { return value }

        // Color values: prefer hex, append alpha if not fully opaque
        if let hex = dict["hex"] as? String {
            if let alpha = dict["alpha"] as? NSNumber, alpha.doubleValue < 1.0 {
                return "\(hex) \(alpha)"
            }
            return hex
        }

        // Generic dict value: emit as ordered dict so YAML recurses into it
        var entries: [(key: String, value: Any)] = []
        for key in dict.keys.sorted() {
            entries.append((key: key, value: flattenValue(dict[key]!)))
        }
        return OrderedDict(entries: entries)
    }

    /// Extract descriptions from token leaves, keyed by their dot-path.
    private func collectDescriptions(_ value: Any, path: String = "") -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }

        if isTokenLeaf(dict) {
            if let desc = dict["$description"] as? String, !desc.isEmpty {
                return [path: desc]
            }
            return [:]
        }

        var result: [String: String] = [:]
        for (key, val) in dict {
            guard !key.hasPrefix("$") else { continue }
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            result.merge(collectDescriptions(val, path: childPath)) { _, new in new }
        }
        return result
    }

    // MARK: - YAML emitter

    private func emitYAML(_ data: [String: Any], sortedKeys: [String]) -> String {
        // Collect descriptions from the raw data before cleaning
        var allDescriptions: [String: String] = [:]
        for key in sortedKeys {
            if let val = data[key] {
                let descs = collectDescriptions(val, path: key)
                allDescriptions.merge(descs) { _, new in new }
            }
        }

        var lines: [String] = []
        for key in sortedKeys {
            guard let val = data[key] else { continue }
            let cleaned = cleanTree(val)
            emitYAMLNode(key: key, value: cleaned, indent: 0, path: key, descriptions: allDescriptions, lines: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func emitYAMLNode(key: String, value: Any, indent: Int, path: String, descriptions: [String: String], lines: inout [String]) {
        let prefix = String(repeating: "  ", count: indent)

        if let ordered = value as? OrderedDict {
            lines.append("\(prefix)\(yamlKey(key)):")
            for entry in ordered.entries {
                let childPath = "\(path).\(entry.key)"
                emitYAMLNode(key: entry.key, value: entry.value, indent: indent + 1, path: childPath, descriptions: descriptions, lines: &lines)
            }
        } else {
            let formatted = yamlScalar(value)
            let comment = descriptions[path].map { "  # \($0)" } ?? ""
            lines.append("\(prefix)\(yamlKey(key)): \(formatted)\(comment)")
        }
    }

    private func yamlKey(_ key: String) -> String {
        // Quote keys that contain special characters
        if key.contains(":") || key.contains("#") || key.contains("{") || key.contains("}") ||
           key.contains("[") || key.contains("]") || key.contains(",") || key.contains("&") ||
           key.contains("*") || key.contains("!") || key.contains("|") || key.contains(">") ||
           key.contains("'") || key.contains("\"") || key.contains("%") || key.contains("@") ||
           key.hasPrefix(" ") || key.hasSuffix(" ") {
            return "\"\(key.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return key
    }

    private func yamlScalar(_ value: Any) -> String {
        switch value {
        case let s as String:
            return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        case let n as NSNumber:
            // Distinguish bool from number
            if CFBooleanGetTypeID() == CFGetTypeID(n) {
                return n.boolValue ? "true" : "false"
            }
            // Check if it's an integer
            if n.doubleValue == Double(n.intValue) && !n.stringValue.contains(".") {
                return "\(n.intValue)"
            }
            return "\(n)"
        default:
            return "\(value)"
        }
    }

    // MARK: - Markdown emitter

    private func emitMarkdown(_ data: [String: Any], sortedKeys: [String]) -> String {
        var lines: [String] = []
        for key in sortedKeys {
            guard let val = data[key] else { continue }
            lines.append("# \(key)")
            lines.append("")
            emitMarkdownSection(val, path: [], lines: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func emitMarkdownSection(_ value: Any, path: [String], lines: inout [String]) {
        guard let dict = value as? [String: Any] else { return }

        if isTokenLeaf(dict) {
            // Single token — emit as a small table
            let desc = (dict["$description"] as? String).map { " — \($0)" } ?? ""
            if !path.isEmpty {
                let heading = path.joined(separator: " > ")
                lines.append("## \(heading)\(desc)")
                lines.append("")
            }
            lines.append("| property | value |")
            lines.append("|----------|-------|")
            lines.append("| \(path.last ?? "value") | \(formatMDValue(flattenValue(dict["$value"]!))) |")
            lines.append("")
            return
        }

        // Check if all children are token leaves → emit as a properties table
        let childKeys = dict.keys.filter { !$0.hasPrefix("$") }.sorted()
        let allLeaves = childKeys.allSatisfy { isTokenLeaf(dict[$0] as? [String: Any] ?? [:]) }

        if allLeaves && !childKeys.isEmpty {
            if !path.isEmpty {
                let heading = path.joined(separator: " > ")
                lines.append("## \(heading)")
                lines.append("")
            }
            lines.append("| property | value |")
            lines.append("|----------|-------|")
            for childKey in childKeys {
                let leaf = dict[childKey] as! [String: Any]
                let val = formatMDValue(flattenValue(leaf["$value"]!))
                let desc = (leaf["$description"] as? String).map { " (\($0))" } ?? ""
                lines.append("| \(childKey) | \(val)\(desc) |")
            }
            lines.append("")
            return
        }

        // Mixed or nested — recurse
        for childKey in childKeys {
            emitMarkdownSection(dict[childKey]!, path: path + [childKey], lines: &lines)
        }
    }

    private func formatMDValue(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(n) {
                return n.boolValue ? "true" : "false"
            }
            if n.doubleValue == Double(n.intValue) && !n.stringValue.contains(".") {
                return "\(n.intValue)"
            }
            return "\(n)"
        default:
            return "\(value)"
        }
    }
}

// MARK: - OrderedDict

/// Simple ordered dictionary to preserve key order in output.
struct OrderedDict: @unchecked Sendable {
    let entries: [(key: String, value: Any)]
}
