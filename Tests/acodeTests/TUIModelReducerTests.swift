import Foundation
import Testing
@testable import acode

// MARK: - `.usage` reducer (swift-gz9)
//
// The HUD's context-window gauge used to read `m.metrics.inTokens +
// m.metrics.outTokens`, which are session-cumulative. `Agent.run`
// emits ONE usage event per step (up to `maxAgentSteps = 50`), and
// each step's `u.input` is the full (re-sent) prompt size. Summing
// across steps therefore over-counted by N× for an N-step turn and
// pegged the gauge in a single response (the live-TUI bug from
// `swift-gz9`). The fix: a separate `contextTokens` snapshot that
// the reducer REPLACES (not `+=`) on every `.usage` event. The
// latest value is also the most accurate "how much context am I
// using right now" — within a multi-step turn, `u.input` grows
// step-over-step as the conversation grows, so the latest event
// naturally converges to the true final context size.
//
// The cumulative `inTokens` / `outTokens` stay as-is for the
// session-cumulative `Metrics.cost` and the `↑/↓` HUD readouts —
// cost is per-token, every turn, so summing is the right
// semantics for that path.

@Suite struct TUIModelReducerTests {

    /// Builds a model with a known `contextWindow` so the gauge
    /// fraction assertion is meaningful.
    private func makeModel(contextWindow: Int) -> TUIModel {
        TUIModel(
            status: Status(
                model: "test-model",
                cwd: "/tmp",
                branch: nil,
                contextWindow: contextWindow
            )
        )
    }

    /// swift-gz9: a multi-step turn with GROWING input must leave
    /// `contextTokens` at the LATEST `u.input + u.output` (replace),
    /// NOT the sum. The cumulative `inTokens` / `outTokens` MUST
    /// still be the sum (cost path is unchanged).
    @Test func usageReducerContextSnapshotIsReplace() {
        var m = makeModel(contextWindow: 200_000)

        // Step 1: input 1500, output 200 → context window 1700.
        update(&m, .usage(Usage(input: 1500, output: 200)))
        #expect(m.metrics.contextTokens == 1700,
                "contextTokens should equal input+output of the latest event (1500+200=1700)")
        #expect(m.metrics.inTokens == 1500,
                "inTokens is the cumulative SUM (cost path)")
        #expect(m.metrics.outTokens == 200,
                "outTokens is the cumulative SUM (cost path)")
        #expect(m.metrics.turnOutTokens == 200,
                "turnOutTokens is per-turn output (drives tokPerSec)")

        // Step 2: input grows to 2200, output 350 → context 2550.
        update(&m, .usage(Usage(input: 2200, output: 350)))
        #expect(m.metrics.contextTokens == 2550,
                "contextTokens should REPLACE to 2200+350=2550, not sum to 4250")
        #expect(m.metrics.inTokens == 1500 + 2200,
                "inTokens keeps accumulating (3700 across 2 steps)")
        #expect(m.metrics.outTokens == 200 + 350,
                "outTokens keeps accumulating (550 across 2 steps)")
        #expect(m.metrics.turnOutTokens == 200 + 350,
                "turnOutTokens is per-turn (resets at .submitTask in the loop)")

        // Step 3: input 3000, output 400 → context 3400.
        update(&m, .usage(Usage(input: 3000, output: 400)))
        #expect(m.metrics.contextTokens == 3400,
                "contextTokens is the LATEST (3000+400=3400), not the sum (9400)")
        #expect(m.metrics.inTokens == 1500 + 2200 + 3000,
                "inTokens is still the sum across all steps (6700)")
        #expect(m.metrics.outTokens == 200 + 350 + 400,
                "outTokens is still the sum across all steps (950)")
        #expect(m.metrics.turnOutTokens == 200 + 350 + 400,
                "turnOutTokens is still per-turn (950)")
    }

    /// The HUD's gauge must be small for a normal turn against a
    /// 128k or 200k context window. The bug had it peg at ~100%
    /// mid-response because of the over-counting. This test is the
    /// direct regression guard.
    @Test func contextGaugeFractionIsSmallForNormalTurn() {
        // The live-TUI bug: a single ~15s response (the user's
        // session, a real 10-step turn) pegged the gauge at ~1005,
        // i.e., 10× the context window — the N=10 over-count from
        // summing the full re-sent prompt across N steps. We
        // simulate a realistic 10-step turn where the final input
        // is ~25k tokens (the actual context at the end of the
        // turn) and verify:
        //   - contextTokens (the FIX) reads the latest 25k.
        //   - inTokens + outTokens (the BUG) sums to ~150k+.
        //   - 150k+ / 128k is > 1.0, i.e., the gauge WOULD HAVE
        //     pegged on the old code, confirming the regression.
        var m128 = makeModel(contextWindow: 128_000)
        var m200 = makeModel(contextWindow: 200_000)

        // 10 steps; input grows from 5k to 25k as the conversation
        // grows, output ~1k per step (typical code-task pace).
        let steps: [Usage] = [
            Usage(input: 5_000,  output: 900),
            Usage(input: 8_000,  output: 1_100),
            Usage(input: 11_000, output: 1_200),
            Usage(input: 14_000, output: 1_100),
            Usage(input: 16_000, output: 1_300),
            Usage(input: 18_000, output: 1_000),
            Usage(input: 20_000, output: 1_400),
            Usage(input: 22_000, output: 1_100),
            Usage(input: 24_000, output: 1_200),
            Usage(input: 25_000, output: 1_000),  // final step
        ]
        for u in steps {
            update(&m128, .usage(u))
            update(&m200, .usage(u))
        }

        // contextTokens == LATEST input+output = 26_000
        #expect(m128.metrics.contextTokens == 26_000)
        #expect(m200.metrics.contextTokens == 26_000)

        // 26_000 / 128_000 = 20%
        // 26_000 / 200_000 = 13%
        let fraction128 = Double(m128.metrics.contextTokens) / Double(128_000)
        let fraction200 = Double(m200.metrics.contextTokens) / Double(200_000)
        #expect(fraction128 < 0.30,
                "Context gauge fraction must be <30% for a normal turn on a 128k window (was pegged at >100% before swift-gz9)")
        #expect(fraction200 < 0.20,
                "Context gauge fraction must be <20% for a normal turn on a 200k window")

        // Sanity: the BUGGY behavior (using inTokens+outTokens) would
        // have pegged the gauge. Sum of inputs (5+8+11+14+16+18+20+22+24+25)
        // = 163_000. Sum of outputs (0.9+1.1+1.2+1.1+1.3+1.0+1.4+1.1+1.2+1.0)
        // = 11_300. Total: 174_300. 174_300 / 128_000 = 1.36 →
        // gauge would peg at 136% (clamped to 100% visually).
        let buggyNumerator = m128.metrics.inTokens + m128.metrics.outTokens
        #expect(m128.metrics.contextTokens < buggyNumerator,
                "contextTokens (latest snapshot) must be smaller than the buggy cumulative sum")
        #expect(Double(buggyNumerator) / Double(128_000) > 1.0,
                "The OLD gauge argument WOULD have pegged at >100% with this realistic 10-step data — confirms the bug we're fixing")
    }

    /// The `max(contextWindow, 1)` guard in the gauge must not be
    /// the thing masking a zero denominator. OpenAIProvider's
    /// default is 128_000; AnthropicProvider's is 200_000; the
    /// Config registry only OVERRIDES these — it never sets a
    /// 0/negative value. A custom model with no explicit
    /// `contextWindow` falls through to the provider's own
    /// default, not 0.
    @Test func customProviderContextWindowDefaultsToProviderFloor() {
        // This is a documentation-of-behavior test. The actual
        // resolution lives in `Config.makeProvider`. We verify the
        // provider classes' defaults are non-zero so the gauge
        // guard isn't masking a config bug.
        let openai = OpenAIProvider(configuredModel: "deepseek-v4-pro")
        #expect(openai.contextWindow > 0,
                "OpenAIProvider default contextWindow must be non-zero (currently 128_000)")
        #expect(openai.contextWindow == 128_000,
                "OpenAIProvider default is 128_000 (the value the gauge denominator would resolve to for an unconfigured custom OpenAI-compatible model)")

        let anthropic = AnthropicProvider(configuredModel: "claude-test")
        #expect(anthropic.contextWindow > 0,
                "AnthropicProvider default contextWindow must be non-zero (currently 200_000)")
        #expect(anthropic.contextWindow == 200_000,
                "AnthropicProvider default is 200_000 (the value the gauge denominator would resolve to for an unconfigured custom Anthropic model)")

        // A custom model with no registry entry resolves to one
        // of the above two floors. Either is >> 0, so the
        // `max(contextWindow, 1)` guard in the gauge is purely
        // defensive and never masks a real misconfiguration.
        #expect(min(openai.contextWindow, anthropic.contextWindow) >= 1,
                "The min of the two provider defaults is at least 1 — the gauge guard never has to fire")
    }
}
