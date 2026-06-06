import Foundation

/// Maximum number of lines returned by an uncapped `read_file` read.
private let readFileLineCap = 2000

/// Directory names excluded from listing and traversal.
nonisolated let ignoredDirectoryNames: Set<String> = [
    ".git", ".build", "DerivedData", "node_modules", ".venv", "dist"
]

/// Maximum number of grep hits returned.
private nonisolated let grepHitCap = 50

/// Reads a file under the project root, optionally a line range.
struct ReadFileTool: Tool {
    let requiresApproval = false

    static var schema: ToolSchema {
        ToolSchema(
            name: "read_file",
            description: "Read a UTF-8 text file under the project root, optionally a line range.",
            parameters: Schema.object(
                [
                    "path": (type: "string", description: "Path to the file, relative to the project root."),
                    "start_line": (type: "integer", description: "Optional 1-based first line to return."),
                    "num_lines": (type: "integer", description: "Optional number of lines to return from start_line.")
                ],
                required: ["path"]
            )
        )
    }

    func run(_ args: JSONValue) async -> ToolOutput {
        guard let path = args["path"]?.stringValue else {
            return ToolOutput(output: "Missing required argument: path.", isError: true)
        }
        do {
            let url = try ProjectJail.resolve(path)
            let contents = try String(contentsOf: url, encoding: .utf8)
            let lines = contents.components(separatedBy: "\n")

            if let start = args["start_line"]?.intValue {
                let count = args["num_lines"]?.intValue ?? (lines.count - (start - 1))
                guard start >= 1, start <= lines.count else {
                    return ToolOutput(
                        output: "start_line \(start) is out of range (file has \(lines.count) lines).",
                        isError: true
                    )
                }
                let lower = start - 1
                let upper = min(lines.count, lower + max(0, count))
                let slice = lines[lower..<upper].joined(separator: "\n")
                return ToolOutput(output: slice)
            }

            if lines.count > readFileLineCap {
                let clipped = lines[0..<readFileLineCap].joined(separator: "\n")
                let note = "\n[truncated: showing first \(readFileLineCap) of \(lines.count) lines]"
                return ToolOutput(output: clipped + note)
            }
            return ToolOutput(output: contents)
        } catch {
            return ToolOutput(output: "Could not read \(path): \(error.localizedDescription)", isError: true)
        }
    }
}

/// Lists one directory level under the project root, excluding ignored dirs.
struct ListFilesTool: Tool {
    let requiresApproval = false

    static var schema: ToolSchema {
        ToolSchema(
            name: "list_files",
            description: "List the contents of a directory (one level) under the project root.",
            parameters: Schema.object(
                ["path": (type: "string", description: "Directory path, relative to the project root. Defaults to \".\".")],
                required: []
            )
        )
    }

    func run(_ args: JSONValue) async -> ToolOutput {
        let path = args["path"]?.stringValue ?? "."
        do {
            let url = try ProjectJail.resolve(path)
            let entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )

            var lines: [String] = []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory && ignoredDirectoryNames.contains(name) {
                    continue
                }
                lines.append(isDirectory ? "\(name)/" : name)
            }

            if lines.isEmpty {
                return ToolOutput(output: "(empty)")
            }
            return ToolOutput(output: lines.joined(separator: "\n"))
        } catch {
            return ToolOutput(output: "Could not list \(path): \(error.localizedDescription)", isError: true)
        }
    }
}

/// Searches file contents for a regex pattern under the project root.
///
/// Uses `rg --json` when available, otherwise an NSRegularExpression walk with
/// the same ignore rules. Output shape is identical for both backends:
/// `relative/path:lineNumber: matched line`.
struct GrepTool: Tool {
    let requiresApproval = false

    static var schema: ToolSchema {
        ToolSchema(
            name: "grep",
            description: "Search file contents for a regular-expression pattern under the project root.",
            parameters: Schema.object(
                [
                    "pattern": (type: "string", description: "The regular-expression pattern to search for."),
                    "path": (type: "string", description: "Directory or file to search, relative to the project root. Defaults to \".\".")
                ],
                required: ["pattern"]
            )
        )
    }

    func run(_ args: JSONValue) async -> ToolOutput {
        guard let pattern = args["pattern"]?.stringValue else {
            return ToolOutput(output: "Missing required argument: pattern.", isError: true)
        }
        let path = args["path"]?.stringValue ?? "."
        do {
            let url = try ProjectJail.resolve(path)
            let hits = Self.ripgrepHits(pattern: pattern, path: path)
                ?? Self.fallbackHits(pattern: pattern, root: url)

            if hits.isEmpty {
                return ToolOutput(output: "No matches.")
            }
            if hits.count > grepHitCap {
                let capped = hits.prefix(grepHitCap).joined(separator: "\n")
                return ToolOutput(output: capped + "\n[truncated: showing first \(grepHitCap) matches]")
            }
            return ToolOutput(output: hits.joined(separator: "\n"))
        } catch {
            return ToolOutput(output: "Could not search \(path): \(error.localizedDescription)", isError: true)
        }
    }

    /// Runs `rg --json` from the project root. Returns nil when rg is
    /// unavailable so the caller can fall back.
    private nonisolated static func ripgrepHits(pattern: String, path: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rg", "--json", pattern, path]
        process.currentDirectoryURL = URL(fileURLWithPath: ProjectJail.root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // 127 = env could not find rg; treat as unavailable.
        if process.terminationStatus == 127 {
            return nil
        }

        var hits: [String] = []
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let lineData = line.data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                root["type"] as? String == "match",
                let payload = root["data"] as? [String: Any],
                let pathObject = payload["path"] as? [String: Any],
                let relPath = pathObject["text"] as? String,
                let lineNumber = payload["line_number"] as? Int,
                let linesObject = payload["lines"] as? [String: Any],
                let matchedLine = linesObject["text"] as? String
            else {
                continue
            }
            let trimmed = matchedLine.trimmingCharacters(in: .newlines)
            let normalizedPath = relPath.hasPrefix("./") ? String(relPath.dropFirst(2)) : relPath
            hits.append("\(normalizedPath):\(lineNumber): \(trimmed)")
        }
        return hits
    }

    /// Walks files under `root` and matches lines with NSRegularExpression,
    /// applying the same ignore rules as list_files.
    private nonisolated static func fallbackHits(pattern: String, root: URL) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let fm = FileManager.default
        let rootPath = URL(fileURLWithPath: ProjectJail.root).standardizedFileURL.path

        var files: [URL] = []
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            files = [root]
        } else if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let entry as URL in enumerator {
                let entryIsDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if entryIsDir {
                    if ignoredDirectoryNames.contains(entry.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                files.append(entry)
            }
        }

        var hits: [String] = []
        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let relPath = relativePath(of: file.standardizedFileURL.path, under: rootPath)
            let lines = contents.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    hits.append("\(relPath):\(index + 1): \(line)")
                    if hits.count > grepHitCap {
                        return hits
                    }
                }
            }
        }
        return hits
    }

    /// Computes a project-root-relative path for display.
    private nonisolated static func relativePath(of path: String, under root: String) -> String {
        if path == root { return "." }
        let prefix = root + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }
}

/// Creates or edits a file under the project root. Mutating, so it requires
/// approval. Writes atomically and never throws (invariant B3).
struct EditFileTool: Tool {
    let requiresApproval = true

    static var schema: ToolSchema {
        ToolSchema(
            name: "edit_file",
            description: "Create or edit a file under the project root. Empty old_str creates the file.",
            parameters: Schema.object(
                [
                    "path": (type: "string", description: "Path to the file, relative to the project root."),
                    "old_str": (type: "string", description: "Exact text to replace. Empty or omitted creates the file only if it does not already exist; it will NOT overwrite an existing file."),
                    "new_str": (type: "string", description: "Replacement text (or the file's contents in create mode).")
                ],
                required: ["path", "new_str"]
            )
        )
    }

    func run(_ args: JSONValue) async -> ToolOutput {
        guard let path = args["path"]?.stringValue else {
            return ToolOutput(output: "Missing required argument: path.", isError: true)
        }
        guard let newStr = args["new_str"]?.stringValue else {
            return ToolOutput(output: "Missing required argument: new_str.", isError: true)
        }
        let oldStr = args["old_str"]?.stringValue ?? ""

        do {
            let url = try ProjectJail.resolve(path)
            let fileExists = FileManager.default.fileExists(atPath: url.path)

            // Create mode: only when the file does not yet exist.
            if !fileExists {
                try Self.atomicWrite(newStr, to: url)
                return ToolOutput(output: "Created \(path) (\(newStr.count) bytes).")
            }

            // The file exists. An empty old_str is ambiguous and would replace
            // the entire file, so refuse it rather than silently clobbering the
            // contents — the caller must name the exact text to replace.
            if oldStr.isEmpty {
                return ToolOutput(
                    output: "\(path) already exists; provide a non-empty old_str naming the exact text to replace "
                        + "(an empty old_str would overwrite the whole file).",
                    isError: true
                )
            }

            let content = try String(contentsOf: url, encoding: .utf8)
            let exactCount = Self.countOccurrences(of: oldStr, in: content)

            if exactCount == 1 {
                let updated = content.replacingOccurrences(of: oldStr, with: newStr)
                try Self.atomicWrite(updated, to: url)
                return ToolOutput(output: "Edited \(path).")
            }
            if exactCount > 1 {
                return ToolOutput(
                    output: "old_str must match exactly once; found \(exactCount) occurrences in \(path).",
                    isError: true
                )
            }

            // Zero exact matches: whitespace-normalized line fallback (D4).
            if let updated = Self.normalizedReplace(oldStr: oldStr, newStr: newStr, in: content) {
                try Self.atomicWrite(updated, to: url)
                return ToolOutput(output: "Edited \(path) (normalized match).")
            }
            return ToolOutput(
                output: "old_str must match exactly once; found 0 occurrences in \(path) (including a whitespace-normalized retry).",
                isError: true
            )
        } catch {
            return ToolOutput(output: "Could not edit \(path): \(error.localizedDescription)", isError: true)
        }
    }

    /// Counts non-overlapping occurrences of `needle` in `haystack`.
    private nonisolated static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    /// Normalizes a line: collapse all whitespace runs to single spaces and trim.
    private nonisolated static func normalize(_ line: String) -> String {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// Attempts a line-window replacement using whitespace-normalized matching.
    /// Returns the updated content only when exactly one window matches.
    private nonisolated static func normalizedReplace(oldStr: String, newStr: String, in content: String) -> String? {
        let fileLines = content.components(separatedBy: "\n")
        let oldLines = oldStr.components(separatedBy: "\n")
        guard !oldLines.isEmpty, oldLines.count <= fileLines.count else { return nil }

        let normFile = fileLines.map(normalize)
        let normOld = oldLines.map(normalize)

        var matchStarts: [Int] = []
        for start in 0...(fileLines.count - oldLines.count) {
            if Array(normFile[start..<start + oldLines.count]) == normOld {
                matchStarts.append(start)
            }
        }
        guard matchStarts.count == 1, let start = matchStarts.first else { return nil }

        var updatedLines = fileLines
        updatedLines.replaceSubrange(
            start..<start + oldLines.count,
            with: newStr.components(separatedBy: "\n")
        )
        return updatedLines.joined(separator: "\n")
    }

    /// Writes `content` atomically via a same-directory temp file and rename,
    /// creating parent directories and cleaning up the temp on failure.
    private nonisolated static func atomicWrite(_ content: String, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".acode-tmp-\(UUID().uuidString)")
        do {
            try content.write(to: temp, atomically: false, encoding: .utf8)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
