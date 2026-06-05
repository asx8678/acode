import Foundation

/// Maximum number of lines returned by an uncapped `read_file` read.
private let readFileLineCap = 2000

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
