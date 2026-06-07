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
    ///   - providerForProfile: Optional resolver that returns the provider to
    ///     use for a given profile. When nil, `provider` is used for every
    ///     phase. This lets per-role model overrides (`Config.roleModels`) route
    ///     to the correct provider instead of forcing one provider's API to
    ///     accept another provider's model id.
    /// - Returns: The final answer string (the last coder output).
    func run(
        task: String,
        provider: any LLMProvider,
        tools: ToolRegistry,
        renderer: any RenderSink,
        profiles: (planner: AgentProfile, coder: AgentProfile, reviewer: AgentProfile) = (.planner, .coder, .reviewer),
        providerForProfile: (@MainActor (AgentProfile) -> any LLMProvider)? = nil
    ) async throws -> String {
        let providerFor: @MainActor (AgentProfile) -> any LLMProvider = providerForProfile ?? { _ in provider }

        // MARK: Phase 1 — Planning

        try Task.checkCancellation()
        renderer.phase("Planning")
        let planner = Agent(profile: profiles.planner, provider: providerFor(profiles.planner), tools: tools, renderer: renderer)
        let plan = try await planner.run("Plan the following task:\n\n\(task)")
        renderer.endAssistant()

        // MARK: Phase 2 — Coder/Review loop

        // One coder Agent for the whole loop so it retains its own history and
        // does not re-derive the plan from scratch on every round.
        let coder = Agent(profile: profiles.coder, provider: providerFor(profiles.coder), tools: tools, renderer: renderer)
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
                coderInput = "Address the following review feedback on your implementation:\n\n\(feedback)"
            }
            lastCoderOutput = try await coder.run(coderInput)
            renderer.endAssistant()

            // Reviewer — a fresh Agent each round (each review is independent and
            // re-reads the working tree). Pointed at the actual diff so it does
            // not have to rediscover the changes blind.
            try Task.checkCancellation()
            renderer.phase("Reviewing (round \(round)/\(maxReviewRounds))")
            let reviewer = Agent(profile: profiles.reviewer, provider: providerFor(profiles.reviewer), tools: tools, renderer: renderer)
            let reviewOutput = try await reviewer.run(
                "Review the implementation against the plan.\n\nPlan:\n\(plan)\n\n"
                + "The coder reported:\n\(lastCoderOutput)\n\n"
                + "Inspect the actual changes (e.g. run `git diff`, read the touched files) and check them "
                + "against the plan for bugs, security issues, and edge cases. "
                + "Output VERDICT: APPROVED or VERDICT: CHANGES on the last line."
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
