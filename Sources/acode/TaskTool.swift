import Foundation

// MARK: - SetTasksTool

/// `set_tasks` — the model maintains an in-session todo list. The tool
/// replaces the entire list each time it's called; the model is the source
/// of truth (TUI_PLAN §3, Metrics for the types it operates on).
///
/// Arguments:
///   - `tasks`: a JSON array of `{"title": String, "state": String}` where
///     `state` is one of `pending` / `running` / `done` / `failed`.
///
/// The tool returns the echoed JSON array so the `TUISink` can post a
/// `Msg.setTasks` to the MVU loop (the model has just told us the new
/// list; the UI wants to display it). The array is re-serialized as a
/// stable JSON string so the sink can parse it back into `[TaskItem]`
/// without depending on this tool's internal types.
///
/// The tool itself does **not** mutate any global state — the sink
/// owns the row in the model. This keeps the tool pure-ish (a `Tool.run`
/// never throws, per invariant B3) and makes it trivial to test.
struct SetTasksTool: Tool {
    static let schema = ToolSchema(
        name: "set_tasks",
        description: "Set the in-session todo list. The model owns the list; call this when the plan or its progress changes.",
        parameters: Schema.object(
            [
                "tasks": (
                    type: "array",
                    description: "Array of {title, state} objects. State is one of: pending, running, done, failed."
                )
            ],
            required: ["tasks"]
        )
    )

    /// Setting the task list is safe — it's a UI affordance, not a side
    /// effect. The tool therefore does not require approval.
    let requiresApproval: Bool = false

    func run(_ args: JSONValue) async -> ToolOutput {
        guard case .array(let items) = args["tasks"] ?? .null else {
            return ToolOutput(
                output: "set_tasks: `tasks` must be an array of {title, state} objects.",
                isError: true
            )
        }

        // Normalize each entry so the TUI sees a stable JSON shape.
        var normalized: [[String: String]] = []
        for item in items {
            guard case .object(let dict) = item else {
                return ToolOutput(
                    output: "set_tasks: each task must be an object with a `title` field.",
                    isError: true
                )
            }
            guard let title = dict["title"]?.stringValue, !title.isEmpty else {
                return ToolOutput(
                    output: "set_tasks: every task needs a non-empty `title`.",
                    isError: true
                )
            }
            let stateRaw = dict["state"]?.stringValue?.lowercased() ?? "pending"
            // Whitelist states so the UI never sees an unknown variant.
            let state: String
            switch stateRaw {
            case "done", "running", "failed", "pending": state = stateRaw
            default: state = "pending"
            }
            normalized.append(["title": title, "state": state])
        }

        // Echo the normalized list back as a JSON array. `TUISink` parses
        // it via `JSONSerialization` (which accepts arrays as the root).
        guard let data = try? JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys]
        ),
        let output = String(data: data, encoding: .utf8) else {
            return ToolOutput(
                output: "set_tasks: failed to serialize the task list.",
                isError: true
            )
        }
        return ToolOutput(output: output, isError: false)
    }
}
