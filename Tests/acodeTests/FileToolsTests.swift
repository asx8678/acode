import Foundation
import Testing
@testable import acode

@Test func test_list_files_ignores() async throws {
    let dirName = "acode-list-\(UUID().uuidString)"
    let root = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(dirName)
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // Normal entries.
    try "x".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
    try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    // Ignored directory with content.
    let gitDir = root.appendingPathComponent(".git")
    try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
    try "ref".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

    let tool = ListFilesTool()
    let result = await tool.run(.object(["path": .string(dirName)]))

    #expect(result.isError == false)
    #expect(result.output.contains("readme.txt"))
    #expect(result.output.contains("src/"))
    #expect(!result.output.contains(".git"))
}

@Test func test_grep_finds() async throws {
    let dirName = "acode-grep-\(UUID().uuidString)"
    let dir = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(dirName)
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let token = "ZZUNIQUETOKEN42"
    let body = "first line\nhas \(token) here\nthird line"
    let fileName = "\(dirName)/file.txt"
    try body.write(
        to: URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(fileName),
        atomically: true,
        encoding: .utf8
    )

    let tool = GrepTool()
    let result = await tool.run(.object(["pattern": .string(token), "path": .string(dirName)]))

    #expect(result.isError == false)
    #expect(result.output.contains("\(fileName):2:"))
    #expect(result.output.contains(token))
}

@Test func test_grep_caps() async throws {
    let dirName = "acode-grepcap-\(UUID().uuidString)"
    let dir = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(dirName)
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let token = "CAPTOKEN"
    var lines: [String] = []
    for i in 0..<120 {
        lines.append("line \(i) \(token)")
    }
    try lines.joined(separator: "\n").write(
        to: dir.appendingPathComponent("many.txt"),
        atomically: true,
        encoding: .utf8
    )

    let tool = GrepTool()
    let result = await tool.run(.object(["pattern": .string(token), "path": .string(dirName)]))

    #expect(result.isError == false)
    let hitLines = result.output
        .components(separatedBy: "\n")
        .filter { $0.contains(token) }
    #expect(hitLines.count <= 50)
    #expect(result.output.contains("truncated"))
}

@Test func test_edit_create() async throws {
    let name = "acode-editcreate-\(UUID().uuidString)/new.txt"
    let url = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(name)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let tool = EditFileTool()
    let result = await tool.run(.object([
        "path": .string(name),
        "new_str": .string("created body")
    ]))

    #expect(result.isError == false)
    let written = try String(contentsOf: url, encoding: .utf8)
    #expect(written == "created body")
}

@Test func test_edit_empty_oldstr_refuses_to_clobber_existing() async throws {
    let name = "acode-editclobber-\(UUID().uuidString).txt"
    let url = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(name)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = "important contents"
    try original.write(to: url, atomically: true, encoding: .utf8)

    let tool = EditFileTool()
    let result = await tool.run(.object([
        "path": .string(name),
        "old_str": .string(""),
        "new_str": .string("replacement")
    ]))

    #expect(result.isError == true)
    // The original file must be left untouched.
    let written = try String(contentsOf: url, encoding: .utf8)
    #expect(written == original)
}

@Test func test_edit_unique_replace() async throws {
    let name = "acode-editunique-\(UUID().uuidString).txt"
    let url = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(name)
    defer { try? FileManager.default.removeItem(at: url) }
    try "alpha\nTARGET\nomega".write(to: url, atomically: true, encoding: .utf8)

    let tool = EditFileTool()
    let result = await tool.run(.object([
        "path": .string(name),
        "old_str": .string("TARGET"),
        "new_str": .string("REPLACED")
    ]))

    #expect(result.isError == false)
    let written = try String(contentsOf: url, encoding: .utf8)
    #expect(written == "alpha\nREPLACED\nomega")
}

@Test func test_edit_refuses_nonunique() async throws {
    let name = "acode-editdup-\(UUID().uuidString).txt"
    let url = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(name)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = "dup\nmiddle\ndup"
    try original.write(to: url, atomically: true, encoding: .utf8)

    let tool = EditFileTool()
    let result = await tool.run(.object([
        "path": .string(name),
        "old_str": .string("dup"),
        "new_str": .string("X")
    ]))

    #expect(result.isError == true)
    #expect(result.output.contains("exactly once"))
    let written = try String(contentsOf: url, encoding: .utf8)
    #expect(written == original)
}

@Test func test_edit_atomic() async throws {
    let dirName = "acode-editatomic-\(UUID().uuidString)"
    let dir = URL(fileURLWithPath: ProjectJail.root).appendingPathComponent(dirName)
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let fileURL = dir.appendingPathComponent("file.txt")
    try "one TARGET two".write(to: fileURL, atomically: true, encoding: .utf8)

    let tool = EditFileTool()
    let result = await tool.run(.object([
        "path": .string("\(dirName)/file.txt"),
        "old_str": .string("TARGET"),
        "new_str": .string("DONE")
    ]))

    #expect(result.isError == false)
    let written = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(written == "one DONE two")

    // No stray temp files remain in the directory.
    let remaining = try fm.contentsOfDirectory(atPath: dir.path)
    #expect(remaining == ["file.txt"])
}
