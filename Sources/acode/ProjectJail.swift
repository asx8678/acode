import Foundation

/// Error thrown when a path resolves outside the project root.
///
/// File tools convert thrown errors into `ToolOutput(isError: true)` per
/// invariant B3, so the concrete error type here is not load-bearing.
enum ProjectJailError: Error {
    case outsideProject(String)
}

/// Confines file-tool paths to the project root (the process working directory).
///
/// Note: the jail constrains file tools only. `run_shell` (T0.5) is gated by
/// approval, not by this jail.
enum ProjectJail {
    /// The project root: the process current working directory.
    nonisolated static let root: String = FileManager.default.currentDirectoryPath

    /// Resolves `path` to a standardized, symlink-resolved absolute URL and
    /// throws `ProjectJailError.outsideProject` if it escapes the root.
    static func resolve(_ path: String) throws -> URL {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let candidate: URL
        if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = URL(fileURLWithPath: path, relativeTo: rootURL)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()

        let rootPath = rootURL.path
        let resolvedPath = resolved.path
        let isInRoot = resolvedPath == rootPath
            || resolvedPath.hasPrefix(rootPath + "/")
        guard isInRoot else {
            throw ProjectJailError.outsideProject(path)
        }
        return resolved
    }
}
