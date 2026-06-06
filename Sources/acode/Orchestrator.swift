import Foundation

/// Verdict returned by the reviewer agent on the LAST LINE of its output.
enum Verdict: Sendable {
    case approved
    case changes(feedback: String)

    /// Parses the verdict from the reviewer's full output.
    ///
    /// Only the last non-empty line is examined (so a `VERDICT: APPROVED`
    /// buried mid-text never approves), but matching within that line is
    /// lenient: it is uppercased and its internal whitespace collapsed, then
    /// tested for the `VERDICT: APPROVED` substring. This tolerates trailing
    /// punctuation, markdown emphasis (`**VERDICT: APPROVED**`), and irregular
    /// spacing that real model output routinely produces.
    /// - Anything else → ``changes`` (treat the full output as feedback).
    nonisolated static func parse(from output: String) -> Verdict {
        let lastLine = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""

        let normalized = lastLine
            .uppercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        if normalized.contains("VERDICT: APPROVED") {
            return .approved
        }
        return .changes(feedback: output)
    }
}

/// Multi-agent orchestrator: planner → bounded coder/review loop.
///
/// The planner produces a plan; the coder implements it; the reviewer checks
/// the result. The coder/review loop runs up to `maxReviewRounds` times.
@MainActor
struct Orchestrator {
    /// Maximum coder/review rounds before giving up.
    var maxReviewRounds: Int

    init(maxReviewRounds: Int = 3) {
        self.maxReviewRounds = maxReviewRounds
    }

    /// Runs the full planner → coder/review loop for a given task.
    ///
    /// - Parameters:
    ///   - task: The user's task description.
    ///   - provider: The LLM provider (shared across all phases).
    ///   - tools: The tool registry (shared, with allowlists per profile).
    ///   - renderer: For user-facing output.
    ///   - profiles: The three profiles to use (defaults to `.planner`,
    ///     `.coder`, `.reviewer`).
    /// - Returns: The final answer string (the last coder output).
    func run(
        task: String,
        provider: any LLMProvider,
        tools: ToolRegistry,
        renderer: Renderer,
        profiles: (planner: AgentProfile, coder: AgentProfile, reviewer: AgentProfile) = (.planner, .coder, .reviewer)
    ) async throws -> String {
        // MARK: Phase 1 — Planning

        try Task.checkCancellation()
        renderer.phase("Planning")
        let planner = Agent(profile: profiles.planner, provider: provider, tools: tools, renderer: renderer)
        let plan = try await planner.run("Plan the following task:\n\n\(task)")
        renderer.endAssistant()

        // MARK: Phase 2 — Coder/Review loop

        var feedback = ""
        var lastCoderOutput = ""

        for round in 1...maxReviewRounds {
            try Task.checkCancellation()

            // Coder
            renderer.phase("Coding (round \(round)/\(maxReviewRounds))")
            let coderInput: String
            if round == 1 {
                coderInput = "Implement the following plan:\n\n\(plan)"
            } else {
                coderInput = "Implement the following plan:\n\n\(plan)\n\nReview feedback to address:\n\(feedback)"
            }
            let coder = Agent(profile: profiles.coder, provider: provider, tools: tools, renderer: renderer)
            lastCoderOutput = try await coder.run(coderInput)
            renderer.endAssistant()

            // Reviewer
            try Task.checkCancellation()
            renderer.phase("Reviewing (round \(round)/\(maxReviewRounds))")
            let reviewer = Agent(profile: profiles.reviewer, provider: provider, tools: tools, renderer: renderer)
            let reviewOutput = try await reviewer.run(
                "Review the following implementation against the plan:\n\nPlan:\n\(plan)\n\n"
                + "Review the code changes made. Output VERDICT: APPROVED or VERDICT: CHANGES on the last line."
            )
            renderer.endAssistant()

            switch Verdict.parse(from: reviewOutput) {
            case .approved:
                return lastCoderOutput
            case .changes(let newFeedback):
                feedback = newFeedback
            }
        }

        return "[Max review rounds reached]\n\n\(lastCoderOutput)"
    }
}
