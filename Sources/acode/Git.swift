import Foundation

// MARK: - GitBranch
//
// Reads the active branch of the repo containing `cwd`. We avoid
// shelling out to `git` because the HUD reads this on startup and
// optionally on a slow refresh timer — spawning a process for a
// `cat .git/HEAD` would be wasteful and would block the main actor
// in the slow-timer case. The `.git/HEAD` parse is the canonical
// format the git CLI itself uses; `git rev-parse --abbrev-ref HEAD`
// is just a thin wrapper over it.

/// Detects the current branch of the git repository containing
/// `cwd`. Returns `nil` when:
/// - `cwd` is not inside a git working tree,
/// - the `.git/HEAD` is a detached SHA (we return `nil` rather than
///   a short SHA — the HUD has no use for "abc1234" alongside other
///   human-readable fields), or
/// - the read fails for any reason (permissions, IO error, race
///   during a checkout). All failure modes are silent: the HUD
///   shows nothing, which is the documented "degrade gracefully"
///   requirement.
///
/// **Pure function of the filesystem state at call time.** Safe to
/// call from the main actor. The cost is one stat() per ancestor
/// directory plus a single small file read on hit — well under
/// 1 ms on a warm cache, and we call this at most once per 30 s
/// when the slow refresh timer is wired.
///
/// `nonisolated` so the slow-refresh `Task.detached` in
/// `TUIApp.startBranchRefreshTimer` can call it off the main
/// actor. The function is filesystem-only and uses no actor state.
nonisolated func detectGitBranch(cwd: String) -> String? {
    // Walk up the directory tree until we find a `.git` entry
    // (directory in the common case, file for worktrees). Bound
    // the walk at `/` so a malformed tree can't loop forever.
    var dir = (cwd as NSString).standardizingPath
    let root = "/"
    while true {
        let candidate = (dir as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir)
        if exists {
            return isDir.boolValue
                ? readBranchFromGitDir(at: candidate)
                : readBranchFromGitFile(at: candidate)
        }
        if dir == root { return nil }
        dir = (dir as NSString).deletingLastPathComponent
    }
}

/// Reads `.git/HEAD` for a `.git` *directory*. The standard format is
/// `ref: refs/heads/<branch>\n`; a detached HEAD is a bare 40-char
/// SHA (return nil — see `detectGitBranch`).
private nonisolated func readBranchFromGitDir(at gitDir: String) -> String? {
    let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: headPath)),
          let head = String(data: data, encoding: .utf8)
    else { return nil }
    return parseRefLine(head)
}

/// Reads `.git` for a git *worktree* (where `.git` is a file
/// containing `gitdir: <path>`). The HEAD file lives in that
/// pointed-to directory.
private nonisolated func readBranchFromGitFile(at gitFile: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: gitFile)),
          let content = String(data: data, encoding: .utf8)
    else { return nil }
    // `gitdir: /abs/path/to/.git/worktrees/<name>` — resolve the
    // path relative to the directory containing the `.git` file.
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let colon = trimmed.firstIndex(of: ":") else { return nil }
    let after = trimmed[trimmed.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
    let resolved: String
    if (after as NSString).isAbsolutePath {
        resolved = after
    } else {
        let parent = (gitFile as NSString).deletingLastPathComponent
        resolved = ((parent as NSString).appendingPathComponent(after) as NSString)
            .standardizingPath
    }
    return readBranchFromGitDir(at: resolved)
}

/// Extracts a branch name from a `.git/HEAD` line. Accepts:
/// - `ref: refs/heads/<name>` → returns `<name>`
/// - bare 40-hex-char SHA → returns `nil` (detached)
/// - anything else → returns `nil` (forward-compat for future
///   pseudo-refs like `ref: refs/tags/…`; the HUD has no use for
///   tags and we don't want to render a misclassified branch).
private nonisolated func parseRefLine(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "ref: refs/heads/"
    if trimmed.hasPrefix(prefix) {
        let name = String(trimmed.dropFirst(prefix.count))
        // Refuse empty names and `..` sequences. We INTENTIONALLY
        // allow `/` in the name — the standard branch convention
        // uses slash-prefixed names (`feature/foo`, `release/1.2`,
        // `bugfix/bar`), and the branch is only ever rendered as a
        // HUD display string (`⎇ <branch>`), never used as a
        // filesystem path, so `/` is safe. The `..` guard is
        // belt-and-suspenders against a crafted `.git/HEAD`.
        if name.isEmpty || name.contains("..") {
            return nil
        }
        return name
    }
    // Detached HEAD (or a future pseudo-ref) — no branch name.
    return nil
}
