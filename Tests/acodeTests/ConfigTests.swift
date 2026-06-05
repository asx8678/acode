import Testing
@testable import acode

@MainActor
@Test func test_registers_standard_tools() {
    var registry = ToolRegistry()
    registerStandardTools(&registry)

    let names = Set(registry.schemas(allowed: nil).map(\.name))
    #expect(names == ["read_file", "list_files", "grep", "edit_file", "run_shell"])
}
