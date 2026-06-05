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
