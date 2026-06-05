import Foundation

/// Progressive-disclosure skill system.
///
/// Skills are markdown files stored in `~/.config/acode/skills/` (global) and
/// `./.acode/skills/` (project-local). The index is a lightweight summary
/// injected into the system prompt; the model activates a skill by name to
/// receive its full body as a tool result.
enum Skills {
    /// A single indexed skill entry.
    struct Entry: Sendable {
        let name: String       // filename without .md extension
        let summary: String    // first non-empty line of the file
        let source: URL        // full path to the .md file
    }

    /// The global skill directory: `~/.config/acode/skills/`.
    private nonisolated static var globalDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/acode/skills", isDirectory: true)
    }

    /// The project-local skill directory: `./.acode/skills/`.
    private nonisolated static var projectDirectory: URL {
        URL(fileURLWithPath: ProjectJail.root, isDirectory: true)
            .appendingPathComponent(".acode/skills", isDirectory: true)
    }

    /// Returns true if `name` is a safe, single-component skill name with no
    /// path-traversal potential (no separators and no `..`).
    nonisolated static func isValidName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("..")
    }

    // NOTE: This performs synchronous file I/O on the main actor. Skill files
    // are small and few, so the blocking cost is negligible; acceptable for now.
    /// Reads all `*.md` files from the global and project-local skill
    /// directories. Project-local skills shadow global skills with the
    /// same name (last wins, so project-local takes precedence).
    /// Missing directories are silently skipped.
    nonisolated static func index() -> [Entry] {
        var byName: [String: Entry] = [:]
        // Global first, then project-local so project-local overwrites.
        for directory in [globalDirectory, projectDirectory] {
            for entry in entries(in: directory) {
                byName[entry.name] = entry
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// Returns the full body of the named skill, or nil if not found.
    /// Searches project-local first, then global.
    nonisolated static func body(for name: String) -> String? {
        // Reject path-traversal attempts before touching the filesystem.
        guard isValidName(name) else { return nil }
        let directories = [projectDirectory, globalDirectory]
        for directory in directories {
            let url = directory.appendingPathComponent("\(name).md")
                .standardizedFileURL
                .resolvingSymlinksInPath()
            // Confirm the resolved path is still inside the skills directory.
            let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
            guard url.path.hasPrefix(base + "/") else { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    /// Lists the `*.md` entries in a single directory, skipping it if absent.
    private nonisolated static func entries(in directory: URL) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var result: [Entry] = []
        for fileName in names where fileName.hasSuffix(".md") {
            let url = directory.appendingPathComponent(fileName)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = String(fileName.dropLast(3))  // drop ".md"
            let summary = text
                .components(separatedBy: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                .trimmingCharacters(in: .whitespaces) ?? ""
            result.append(Entry(name: name, summary: summary, source: url))
        }
        return result
    }
}

// MARK: - Tools

/// Lists the available skill files and their one-line summaries.
struct ListSkillsTool: Tool {
    let requiresApproval = false

    static var schema: ToolSchema {
        ToolSchema(
            name: "list_skills",
            description: "List available skill files.",
            parameters: Schema.object([:], required: [])
        )
    }

    func run(_ args: JSONValue) async -> ToolOutput {
        let entries = Skills.index()
        guard !entries.isEmpty else {
            return ToolOutput(output: "No skills available.")
        }
        let lines = entries.map { "- \($0.name): \($0.summary)" }
        let body = (["Available skills:"] + lines).joined(separator: "\n")
        return ToolOutput(output: body)
    }
}

/// Activates a skill by name, returning its full body as a tool result.
struct ActivateSkillTool: Tool {
    let requiresApproval = false

    static var schema: ToolSchema {
        ToolSchema(
            name: "activate_skill",
            description: "Activate a skill by name to receive its full instructions.",
            parameters: Schema.object(
                [
                    "name": (type: "string", description: "Name of the skill (filename without .md).")
                ],
                required: ["name"]
            )
        )
    }

    func run(_ args: JSONValue) async -> ToolOutput {
        guard let name = args["name"]?.stringValue else {
            return ToolOutput(output: "Missing required argument: name.", isError: true)
        }
        guard Skills.isValidName(name) else {
            return ToolOutput(output: "Invalid skill name: \(name)", isError: true)
        }
        guard let body = Skills.body(for: name) else {
            return ToolOutput(output: "Unknown skill: \(name)", isError: true)
        }
        return ToolOutput(output: body)
    }
}
