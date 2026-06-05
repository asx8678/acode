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
