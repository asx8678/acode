import Foundation

// MARK: - Lang

/// A small, fixed set of languages the TUI can highlight. Anything not
/// in this set renders as `.plain` (no escapes).
///
/// The spec caps support at Swift / shell / JSON / diff (EPIC §7 / §12).
/// Not a general lexer — regex/best-effort. Capped on purpose: every
/// unsupported extension renders plain, which means a wrong guess costs
/// 0 escapes rather than 100 wrong-colored glyphs.
enum Lang: Sendable, Equatable {
    case swift
    case shell
    case json
    case diff
    case plain
}

// MARK: - detectLang

/// Maps a file path (or just an extension) to a `Lang`. The diff case
/// is selected by an explicit `@@` hunk header on the first line, not
/// by extension, so callers using `highlight(_, .diff, …)` directly
/// won't go through this function.
func detectLang(path: String) -> Lang {
    let lower = path.lowercased()
    // Special-case patch/diff by extension first.
    if lower.hasSuffix(".diff") || lower.hasSuffix(".patch") { return .diff }
    let ext = (lower as NSString).pathExtension
    switch ext {
    case "swift":                                        return .swift
    case "sh", "bash", "zsh":                            return .shell
    case "json", "jsonc", "geojson":                     return .json
    default:                                             return .plain
    }
}

// MARK: - highlight

/// Returns a single-line `String` with embedded SGR escapes for syntax
/// highlighting. The output is one "row" — callers wrap to width.
///
/// **Pure** function of `(line, lang, theme, depth)`. The only I/O-free
/// escape producer is `sgr(_:depth:)`, so a `mono` terminal receives
/// the plain text unchanged.
func highlight(_ line: String, _ lang: Lang, theme: Theme, depth: ColorDepth) -> String {
    switch lang {
    case .swift:  return highlightSwift(line, theme: theme, depth: depth)
    case .shell:  return highlightShell(line, theme: theme, depth: depth)
    case .json:   return highlightJson(line, theme: theme, depth: depth)
    case .diff:   return highlightDiff(line, theme: theme, depth: depth)
    case .plain:  return line
    }
}

// MARK: - Swift

private let swiftKeywords: Set<String> = [
    "import", "func", "let", "var", "if", "else", "guard", "return",
    "while", "for", "in", "do", "try", "catch", "throw", "throws",
    "switch", "case", "default", "break", "continue", "fallthrough",
    "struct", "class", "enum", "protocol", "extension", "typealias",
    "init", "deinit", "self", "Self", "super", "static", "final",
    "private", "fileprivate", "internal", "public", "open",
    "weak", "unowned", "lazy", "mutating", "nonmutating",
    "true", "false", "nil", "async", "await", "actor", "isolated",
    "nonisolated", "throws", "rethrows", "associatedtype", "inout",
    "where", "as", "is", "some", "any"
]

private let swiftTypes: Set<String> = [
    "Int", "UInt", "Int8", "Int16", "Int32", "Int64",
    "UInt8", "UInt16", "UInt32", "UInt64",
    "Double", "Float", "Bool", "String", "Character", "Array",
    "Dictionary", "Set", "Optional", "Result", "Data", "Date",
    "URL", "UUID", "Void", "Never"
]

private func highlightSwift(_ line: String, theme: Theme, depth: ColorDepth) -> String {
    // 1. Comments win — if the line contains `//`, color from there.
    if let commentStart = line.range(of: "//") {
        let code = String(line[..<commentStart.lowerBound])
        let comment = String(line[commentStart.lowerBound...])
        return highlightSwiftCode(code, theme: theme, depth: depth)
            + sgr(theme.dim, depth) + comment + sgrReset()
    }
    return highlightSwiftCode(line, theme: theme, depth: depth)
}

private func highlightSwiftCode(_ line: String, theme: Theme, depth: ColorDepth) -> String {
    var out = ""
    var i = line.startIndex
    while i < line.endIndex {
        let c = line[i]
        // String literal: take until the next unescaped quote.
        if c == "\"" {
            let end = scanQuotedSwiftString(line, from: i)
            out += sgr(theme.ok, depth) + String(line[i..<end]) + sgrReset()
            i = end
            continue
        }
        // Identifier or keyword.
        if c.isLetter || c == "_" {
            var j = i
            while j < line.endIndex, line[j].isLetter || line[j].isNumber || line[j] == "_" {
                j = line.index(after: j)
            }
            let word = String(line[i..<j])
            let colored: String
            if swiftKeywords.contains(word) {
                colored = sgr(theme.accentB, depth) + word + sgrReset()
            } else if swiftTypes.contains(word) || (word.first?.isUppercase ?? false) {
                colored = sgr(theme.accentA, depth) + word + sgrReset()
            } else {
                colored = word
            }
            out += colored
            i = j
            continue
        }
        // Number literal.
        if c.isNumber {
            var j = i
            while j < line.endIndex, line[j].isNumber || line[j] == "." || line[j] == "_" {
                j = line.index(after: j)
            }
            out += sgr(theme.warn, depth) + String(line[i..<j]) + sgrReset()
            i = j
            continue
        }
        out.append(c)
        i = line.index(after: i)
    }
    return out
}

/// Walks from `start` (a `"`) to the closing unescaped `"`. Returns
/// the index just past the closing quote (or `endIndex` if no close).
private func scanQuotedSwiftString(_ s: String, from start: String.Index) -> String.Index {
    var i = s.index(after: start)
    while i < s.endIndex {
        if s[i] == "\\", s.index(after: i) < s.endIndex {
            i = s.index(i, offsetBy: 2)
            continue
        }
        if s[i] == "\"" {
            return s.index(after: i)
        }
        i = s.index(after: i)
    }
    return s.endIndex
}

// MARK: - Shell

private func highlightShell(_ line: String, theme: Theme, depth: ColorDepth) -> String {
    var out = ""
    var i = line.startIndex
    // 1. Leading comment (`#`).
    if i < line.endIndex, line[i] == "#" {
        return sgr(theme.dim, depth) + line + sgrReset()
    }
    // 2. First whitespace-delimited token is the command.
    let firstTokEnd: String.Index
    if let sp = line.firstIndex(where: { $0.isWhitespace }) {
        firstTokEnd = sp
    } else {
        firstTokEnd = line.endIndex
    }
    let cmd = String(line[i..<firstTokEnd])
    out += sgr(theme.accentB, depth) + cmd + sgrReset()
    i = firstTokEnd
    // 3. Rest of the line: highlight single-quoted strings + `$VAR`.
    while i < line.endIndex {
        let c = line[i]
        if c == "'" {
            let end = scanDelimited(line, from: i, delim: "'")
            out += sgr(theme.ok, depth) + String(line[i..<end]) + sgrReset()
            i = end
            continue
        }
        if c == "\"" {
            let end = scanDelimited(line, from: i, delim: "\"")
            out += sgr(theme.ok, depth) + String(line[i..<end]) + sgrReset()
            i = end
            continue
        }
        if c == "$" {
            var j = line.index(after: i)
            // ${VAR} or $VAR (or $1, $$)
            if j < line.endIndex, line[j] == "{" {
                j = line.index(after: j)
                while j < line.endIndex, line[j] != "}" { j = line.index(after: j) }
                if j < line.endIndex { j = line.index(after: j) }
            } else {
                while j < line.endIndex, line[j].isLetter || line[j].isNumber || line[j] == "_" {
                    j = line.index(after: j)
                }
            }
            out += sgr(theme.accentA, depth) + String(line[i..<j]) + sgrReset()
            i = j
            continue
        }
        out.append(c)
        i = line.index(after: i)
    }
    return out
}

private func scanDelimited(_ s: String, from start: String.Index, delim: Character) -> String.Index {
    var i = s.index(after: start)
    while i < s.endIndex {
        if s[i] == "\\", s.index(after: i) < s.endIndex {
            i = s.index(i, offsetBy: 2)
            continue
        }
        if s[i] == delim {
            return s.index(after: i)
        }
        i = s.index(after: i)
    }
    return s.endIndex
}

// MARK: - JSON

private func highlightJson(_ line: String, theme: Theme, depth: ColorDepth) -> String {
    var out = ""
    var i = line.startIndex
    while i < line.endIndex {
        let c = line[i]
        if c == "\"" {
            // Look ahead to see if the next non-escaped char is `:` —
            // if so this is a key (dimmed), otherwise a string value.
            let end = scanDelimited(line, from: i, delim: "\"")
            let after = endOfWhitespace(line, from: end)
            let isKey = after < line.endIndex && line[after] == ":"
            let color = isKey ? theme.dim : theme.ok
            out += sgr(color, depth) + String(line[i..<end]) + sgrReset()
            i = end
            continue
        }
        if c.isNumber || c == "-" {
            var j = i
            while j < line.endIndex,
                  line[j].isNumber || line[j] == "." || line[j] == "-" || line[j] == "+"
                    || line[j] == "e" || line[j] == "E" {
                j = line.index(after: j)
            }
            out += sgr(theme.warn, depth) + String(line[i..<j]) + sgrReset()
            i = j
            continue
        }
        // true / false / null
        if c.isLetter {
            var j = i
            while j < line.endIndex, line[j].isLetter { j = line.index(after: j) }
            let word = String(line[i..<j])
            if word == "true" || word == "false" || word == "null" {
                out += sgr(theme.accentB, depth) + word + sgrReset()
            } else {
                out += word
            }
            i = j
            continue
        }
        out.append(c)
        i = line.index(after: i)
    }
    return out
}

private func endOfWhitespace(_ s: String, from start: String.Index) -> String.Index {
    var i = start
    while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
    return i
}

// MARK: - Diff

/// Highlights one diff line. The leading char is consumed: `+` → green
/// (added), `-` → red (removed), ` ` → context (unchanged), `@@` →
/// hunk header (cyan), anything else → plain.
private func highlightDiff(_ line: String, theme: Theme, depth: ColorDepth) -> String {
    guard let first = line.first else { return line }
    switch first {
    case "+":
        return sgr(theme.ok, depth) + line + sgrReset()
    case "-":
        return sgr(theme.err, depth) + line + sgrReset()
    case "@":
        if line.hasPrefix("@@") {
            return sgr(theme.accentA, depth) + line + sgrReset()
        }
        return line
    case " ":
        return line
    default:
        // `diff --git`, `index …`, `--- a/foo`, `+++ b/foo` headers
        if line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return sgr(theme.accentB, depth) + line + sgrReset()
        }
        if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
            return sgr(theme.dim, depth) + line + sgrReset()
        }
        return line
    }
}
