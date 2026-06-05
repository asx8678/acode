import Foundation
import Testing
@testable import acode

@Test func test_jail_allows_inroot() throws {
    let resolved = try ProjectJail.resolve("inside-file.txt")
    let rootURL = URL(fileURLWithPath: ProjectJail.root, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let resolvedRoot = rootURL.path
    #expect(resolved.path == resolvedRoot + "/inside-file.txt")
}

@Test func test_jail_rejects_traversal() {
    #expect(throws: ProjectJailError.self) {
        _ = try ProjectJail.resolve("../../etc/passwd")
    }
}

@Test func test_jail_rejects_absolute_outside() {
    #expect(throws: ProjectJailError.self) {
        _ = try ProjectJail.resolve("/etc/passwd")
    }
}
