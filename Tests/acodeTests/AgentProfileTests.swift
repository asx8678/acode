import Foundation
import Testing
@testable import acode

@Test func test_planner_allowlist_excludes_mutating() {
    let tools = try! #require(AgentProfile.planner.tools)
    #expect(!tools.contains("edit_file"))
    #expect(!tools.contains("run_shell"))
    #expect(tools.contains("read_file"))
    #expect(tools.contains("list_files"))
    #expect(tools.contains("grep"))
}

@Test func test_reviewer_allowlist_excludes_mutating() {
    let tools = try! #require(AgentProfile.reviewer.tools)
    #expect(!tools.contains("edit_file"))
    #expect(tools.contains("run_shell"))
    #expect(tools.contains("read_file"))
    #expect(tools.contains("list_files"))
    #expect(tools.contains("grep"))
}

@Test func test_coder_has_all_tools() {
    #expect(AgentProfile.coder.tools == nil)
}

@Test func test_generalist_has_all_tools() {
    #expect(AgentProfile.generalist.tools == nil)
}

@Test func test_profiles_have_identity_and_rules() {
    let profiles = [
        AgentProfile.generalist,
        AgentProfile.planner,
        AgentProfile.coder,
        AgentProfile.reviewer,
    ]
    for profile in profiles {
        #expect(!profile.identity.isEmpty)
        #expect(!profile.rules.isEmpty)
    }
}
