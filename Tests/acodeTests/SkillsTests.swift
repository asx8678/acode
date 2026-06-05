import Foundation
import Testing
@testable import acode

/// Creates `./.acode/skills/` under the project root and returns its URL.
private func makeSkillsDir() throws -> URL {
    let dir = URL(fileURLWithPath: ProjectJail.root, isDirectory: true)
        .appendingPathComponent(".acode/skills", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func test_skills_index_reads_md() async throws {
    let dir = try makeSkillsDir()
    let fm = FileManager.default

    let nameA = "zz-alpha-\(UUID().uuidString)"
    let nameB = "zz-beta-\(UUID().uuidString)"
    let urlA = dir.appendingPathComponent("\(nameA).md")
    let urlB = dir.appendingPathComponent("\(nameB).md")
    defer {
        try? fm.removeItem(at: urlA)
        try? fm.removeItem(at: urlB)
    }

    try "Alpha summary line\nmore alpha content".write(to: urlA, atomically: true, encoding: .utf8)
    try "Beta summary line\nmore beta content".write(to: urlB, atomically: true, encoding: .utf8)

    let entries = Skills.index()
    let alpha = try #require(entries.first { $0.name == nameA })
    let beta = try #require(entries.first { $0.name == nameB })
    #expect(alpha.summary == "Alpha summary line")
    #expect(beta.summary == "Beta summary line")
}

@Test func test_activate_returns_body() async throws {
    let dir = try makeSkillsDir()
    let fm = FileManager.default
    let name = "zz-body-\(UUID().uuidString)"
    let url = dir.appendingPathComponent("\(name).md")
    defer { try? fm.removeItem(at: url) }

    let content = "Title line\n\nFull skill body with details."
    try content.write(to: url, atomically: true, encoding: .utf8)

    let body = try #require(Skills.body(for: name))
    #expect(body == content)
}

@Test func test_activate_unknown_errors() async throws {
    let missing = "zz-nonexistent-\(UUID().uuidString)"
    #expect(Skills.body(for: missing) == nil)

    let tool = ActivateSkillTool()
    let result = await tool.run(.object(["name": .string(missing)]))
    #expect(result.isError == true)
    #expect(result.output.contains("Unknown skill"))
}

@Test func test_list_skills_tool() async throws {
    let dir = try makeSkillsDir()
    let fm = FileManager.default
    let name = "zz-listed-\(UUID().uuidString)"
    let url = dir.appendingPathComponent("\(name).md")
    defer { try? fm.removeItem(at: url) }

    try "Listed summary line\nbody".write(to: url, atomically: true, encoding: .utf8)

    let result = await ListSkillsTool().run(.object([:]))
    #expect(result.isError == false)
    #expect(result.output.contains(name))
    #expect(result.output.contains("Listed summary line"))
}
