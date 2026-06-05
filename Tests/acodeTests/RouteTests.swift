import Testing
@testable import acode

@Test func test_route() {
    guard case .slash(let s) = route("/help") else {
        Issue.record("Expected /help to route to .slash.")
        return
    }
    #expect(s == "help")

    guard case .shell(let sh) = route("!ls -la") else {
        Issue.record("Expected !ls -la to route to .shell.")
        return
    }
    #expect(sh == "ls -la")

    guard case .task(let t) = route("fix the bug") else {
        Issue.record("Expected plain text to route to .task.")
        return
    }
    #expect(t == "fix the bug")
}

@Test func test_plan_slash() {
    guard case .slash(let s) = route("/plan build a website") else {
        Issue.record("Expected /plan build a website to route to .slash.")
        return
    }
    #expect(s == "plan build a website")
}

@Test func test_model_slash() {
    guard case .slash(let s) = route("/model gpt-5") else {
        Issue.record("Expected /model gpt-5 to route to .slash.")
        return
    }
    #expect(s == "model gpt-5")
}
