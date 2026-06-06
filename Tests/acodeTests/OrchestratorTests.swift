import Foundation
import Testing
@testable import acode

@Test func test_verdict_approved() {
    let verdict = Verdict.parse(from: "Some review text\n\nVERDICT: APPROVED")
    guard case .approved = verdict else {
        Issue.record("Expected .approved.")
        return
    }
}

@Test func test_verdict_changes_requested() {
    let output = "Issues found\n\nVERDICT: CHANGES"
    let verdict = Verdict.parse(from: output)
    guard case .changes(let feedback) = verdict else {
        Issue.record("Expected .changes.")
        return
    }
    #expect(feedback == output)
}

@Test func test_verdict_ignores_midtext() {
    let verdict = Verdict.parse(from: "VERDICT: APPROVED is not the last line\nMore text here")
    guard case .changes = verdict else {
        Issue.record("Expected .changes when VERDICT: APPROVED is not last line.")
        return
    }
}

@Test func test_verdict_defaults_to_changes() {
    let verdict = Verdict.parse(from: "Some random output without a verdict keyword")
    guard case .changes = verdict else {
        Issue.record("Expected .changes by default.")
        return
    }
}

@MainActor
@Test func test_orchestrator_converges() async throws {
    let provider = FakeProvider(scripts: [
        // Planner
        [.textDelta("PLAN: do the thing"), .done(stop: "end_turn", usage: Usage())],
        // Coder (round 1)
        [.textDelta("CODE: did the thing"), .done(stop: "end_turn", usage: Usage())],
        // Reviewer (round 1)
        [.textDelta("Looks good\nVERDICT: APPROVED"), .done(stop: "end_turn", usage: Usage())]
    ])

    var tools = ToolRegistry()
    registerStandardTools(&tools)
    let renderer = Renderer(color: false, verbose: false, policy: ApprovalPolicy(autoApproveAll: true))
    let orchestrator = Orchestrator()

    let answer = try await orchestrator.run(
        task: "build a feature",
        provider: provider,
        tools: tools,
        renderer: renderer
    )

    #expect(answer == "CODE: did the thing")
}

@MainActor
@Test func test_orchestrator_multi_round() async throws {
    let provider = FakeProvider(scripts: [
        // Planner
        [.textDelta("PLAN: do the thing"), .done(stop: "end_turn", usage: Usage())],
        // Coder (round 1)
        [.textDelta("first attempt"), .done(stop: "end_turn", usage: Usage())],
        // Reviewer (round 1)
        [.textDelta("Issues found\n\nVERDICT: CHANGES"), .done(stop: "end_turn", usage: Usage())],
        // Coder (round 2)
        [.textDelta("second attempt fixed"), .done(stop: "end_turn", usage: Usage())],
        // Reviewer (round 2)
        [.textDelta("Looks good\n\nVERDICT: APPROVED"), .done(stop: "end_turn", usage: Usage())]
    ])

    var tools = ToolRegistry()
    registerStandardTools(&tools)
    let renderer = Renderer(color: false, verbose: false, policy: ApprovalPolicy(autoApproveAll: true))
    let orchestrator = Orchestrator()

    let answer = try await orchestrator.run(
        task: "build a feature",
        provider: provider,
        tools: tools,
        renderer: renderer
    )

    #expect(answer == "second attempt fixed")
}
