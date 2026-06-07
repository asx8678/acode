import Foundation

// MARK: - Metrics

/// Cumulative + rolling per-turn statistics surfaced on the HUD.
/// **Pure data** — `tokPerSec` and `cost` are computed by the caller from
/// the timestamp the loop captures (no `Date.now` inside the struct, per
/// the TUI_PLAN §6 verification story).
struct Metrics: Sendable, Equatable {
    /// Session-cumulative input tokens. Used by the cost calculator
    /// (you pay per token across the whole session) and the
    /// `↑<in>` HUD readout. Does NOT drive the context gauge —
    /// see `contextTokens` for that. Reset behavior is the
    /// reducer's choice; currently session-cumulative.
    var inTokens: Int = 0
    /// Session-cumulative output tokens. Used by the cost
    /// calculator and the `↓<out>` HUD readout. The
    /// per-turn-equivalent for the tok/s rate is `turnOutTokens`.
    /// Reset behavior is the reducer's choice; currently
    /// session-cumulative.
    var outTokens: Int = 0
    /// Per-turn output tokens, reset to 0 at every `.submitTask`
    /// effect by the loop. Drives `tokPerSec` (which is
    /// per-turn, not session-wide) so the rate stays meaningful
    /// across a multi-turn session. `outTokens` stays
    /// session-cumulative for the cost path — `tokPerSec` and
    /// `cost` have different windows on purpose.
    var turnOutTokens: Int = 0
    /// Latest snapshot of the prompt size, in tokens, reported by
    /// the most recent `.usage` event. The reducer REPLACES
    /// this each event (does NOT add) because each `Usage.input`
    /// the provider reports is the full (re-sent) prompt size
    /// for that step — adding them would over-count by N× for an
    /// N-step turn and peg the HUD's context gauge at the
    /// end of a single response (the bug from `swift-gz9`).
    /// Within a multi-step turn, `u.input` grows step-over-step
    /// as the conversation grows, so the latest value is also
    /// the most accurate view of "how much context am I using
    /// right now." Drove the previous gauge argument
    /// `inTokens + outTokens`, which was session-cumulative and
    /// had no relationship to current context occupancy.
    var contextTokens: Int = 0
    /// Cached input hits. Reserved for future use — the current `Usage`
    /// struct doesn't carry cache info, so this stays 0 in P2.
    var cacheHits: Int = 0
    /// Wall-clock stamp of the first delta of the **current turn**.
    /// The loop sets this at every `.submitTask` effect (not gated
    /// on nil — see `swift-gz9` follow-up: the previous `nil` check
    /// meant it was set only on the first turn ever, which made
    /// `tokPerSec` wildly inflated after turn 1). The reducer
    /// never touches it.
    var firstDeltaAt: Double?
    /// Rolling ring buffer of recent tok/s samples (drives the sparkline).
    /// Capacity is the latest N samples; older samples are dropped.
    var samples: [Int] = []
    /// Maximum samples retained in the ring buffer. 32 ≈ 8s of sparkline
    /// at 4 Hz, which renders cleanly at the HUD's 16-cell width.
    static let sampleCapacity = 32

    /// tok/s since `firstDeltaAt`, using the per-turn `turnOutTokens`
    /// (NOT the session-cumulative `outTokens` — using that would
    /// make the rate blow up after turn 1). Returns 0 if no deltas yet.
    func tokPerSec(now: Double) -> Int {
        guard let start = firstDeltaAt,
              now > start,
              turnOutTokens > 0 else { return 0 }
        let elapsed = now - start
        return Int(Double(turnOutTokens) / elapsed)
    }

    /// Total cost in dollars. Returns `nil` if no pricing info is known
    /// (unknown model → the HUD shows "—" instead).
    func cost(_ p: Pricing?) -> Double? {
        guard let p else { return nil }
        let inCost = Double(inTokens) / 1_000_000.0 * p.inM
        let outCost = Double(outTokens) / 1_000_000.0 * p.outM
        let cacheCost = Double(cacheHits) / 1_000_000.0 * p.cacheM
        return inCost + outCost + cacheCost
    }
}

// MARK: - Pricing

/// Per-million-token prices in USD. `cacheM` is forward-compat for prompt
/// caching (unused in P2 because `Usage.cacheHits` is always 0).
struct Pricing: Sendable, Equatable {
    let inM: Double
    let outM: Double
    let cacheM: Double
}

/// Built-in pricing table (approximate public list prices, USD/Mtok).
/// Owner can override via config in a later wave; until then this is the
/// source of truth for the `$/turn` HUD readout.
enum PricingTable {
    static let perMillionToken: [String: Pricing] = [
        // Anthropic
        "claude-opus-4":       Pricing(inM: 15.0,  outM: 75.0,  cacheM: 18.75),
        "claude-opus-4-1":     Pricing(inM: 15.0,  outM: 75.0,  cacheM: 18.75),
        "claude-sonnet-4":     Pricing(inM: 3.0,   outM: 15.0,  cacheM: 3.75),
        "claude-sonnet-4-5":   Pricing(inM: 3.0,   outM: 15.0,  cacheM: 3.75),
        "claude-haiku-4":      Pricing(inM: 0.80,  outM: 4.0,   cacheM: 1.0),
        "claude-3-5-sonnet":   Pricing(inM: 3.0,   outM: 15.0,  cacheM: 3.75),
        "claude-3-5-haiku":    Pricing(inM: 0.80,  outM: 4.0,   cacheM: 1.0),
        "claude-3-opus":       Pricing(inM: 15.0,  outM: 75.0,  cacheM: 18.75),
        // OpenAI
        "gpt-4o":              Pricing(inM: 2.5,   outM: 10.0,  cacheM: 0),
        "gpt-4o-mini":         Pricing(inM: 0.15,  outM: 0.60,  cacheM: 0),
        "o1":                  Pricing(inM: 15.0,  outM: 60.0,  cacheM: 0),
        "o1-mini":             Pricing(inM: 3.0,   outM: 12.0,  cacheM: 0),
        "o3":                  Pricing(inM: 10.0,  outM: 40.0,  cacheM: 0),
        "o3-mini":             Pricing(inM: 1.10,  outM: 4.40,  cacheM: 0),
        "gpt-4.1":             Pricing(inM: 2.0,   outM: 8.0,   cacheM: 0),
        "gpt-4.1-mini":        Pricing(inM: 0.40,  outM: 1.60,  cacheM: 0),
    ]

    /// Returns the pricing for `model` (exact match first, then prefix
    /// match so `claude-opus-4-20250514` resolves to `claude-opus-4`).
    /// Returns `nil` for unknown models → HUD shows "—".
    static func pricing(for model: String?) -> Pricing? {
        guard let model, !model.isEmpty else { return nil }
        if let p = perMillionToken[model] { return p }
        // Prefix match: try the longest matching key first.
        let candidates = perMillionToken.keys
            .filter { model.hasPrefix($0) }
            .sorted { $0.count > $1.count }
        if let best = candidates.first {
            return perMillionToken[best]
        }
        return nil
    }
}

// MARK: - Task list (P4 prep, defined here for the P3 plan)

/// Lifecycle state of a top-level task in the /tasks view (HUD right pane).
enum TaskState: Sendable, Equatable {
    case done
    case running
    case pending
    case failed
}

// MARK: - Phase (orchestrator timeline, EPIC §2.6)

/// One step in the orchestrator's timeline. Distinct from `TaskItem`
/// because the timeline cares about ordering and a label, not the
/// multi-line progress that the task row handles.
struct Phase: Sendable, Equatable {
    var name: String
    var state: TaskState
}

/// A single entry in the task list. P3 wires the actual rendering; for P2
/// the type is just defined so future changes don't churn the public API.
struct TaskItem: Sendable, Equatable {
    var title: String
    var state: TaskState
}
