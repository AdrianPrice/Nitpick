import AppKit
import Highlighter

// MARK: - Syntax Highlighting Service

/// Provides syntax-highlighted AttributedStrings for diff lines, caching per-file results.
@Observable
final class SyntaxHighlightingService {
    private var highlighter: Highlighter?
    private var cache: [String: [Int: NSAttributedString]] = [:] // fileId -> lineIndex -> attributed
    private var currentAppearanceIsDark: Bool = false

    nonisolated(unsafe) private static var shared: SyntaxHighlightingService?

    /// Shared singleton — Highlighter uses JavaScriptCore so we only want one instance.
    static func instance() -> SyntaxHighlightingService {
        if let existing = shared { return existing }
        let new = SyntaxHighlightingService()
        shared = new
        return new
    }

    private init() {
        highlighter = Highlighter()
        currentAppearanceIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        applyTheme()
    }

    private func applyTheme() {
        let theme = currentAppearanceIsDark ? "atom-one-dark" : "atom-one-light"
        highlighter?.setTheme(theme)
        if let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as NSFont? {
            highlighter?.theme.setCodeFont(font)
        }
    }

    /// Call this when the appearance may have changed to update theme and clear cache.
    func updateAppearanceIfNeeded() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark != currentAppearanceIsDark {
            currentAppearanceIsDark = isDark
            applyTheme()
            cache.removeAll()
        }
    }

    /// Highlight all lines for a file and cache the results.
    /// Returns the highlighted NSAttributedString for a specific line, or nil if unavailable.
    func highlightedLine(for file: DiffFile, lineIndex: Int, content: String) -> NSAttributedString? {
        // Check cache first
        if let fileCached = cache[file.id], let line = fileCached[lineIndex] {
            return line
        }

        // Not cached — highlight the whole file's content at once for better context
        guard let hl = highlighter else { return nil }

        let language = languageForFile(file.path)

        // Build the full file content from all lines (for better language detection)
        let allLines = file.hunks.flatMap(\.lines)
        let fullContent = allLines.map(\.content).joined(separator: "\n")

        guard let attributed = hl.highlight(fullContent, as: language) else { return nil }
        let fullString = attributed.string

        // Split the attributed string by newlines, strip backgrounds, and cache per-line
        var lineResults: [Int: NSAttributedString] = [:]
        var currentIndex = fullString.startIndex
        for (i, _) in allLines.enumerated() {
            let lineEnd = fullString[currentIndex...].firstIndex(of: "\n") ?? fullString.endIndex
            let range = NSRange(currentIndex..<lineEnd, in: fullString)
            let lineAttr = attributed.attributedSubstring(from: range)
            lineResults[i] = Self.stripBackgroundColor(from: lineAttr)
            if lineEnd < fullString.endIndex {
                currentIndex = fullString.index(after: lineEnd)
            } else {
                currentIndex = fullString.endIndex
            }
        }

        cache[file.id] = lineResults
        return lineResults[lineIndex]
    }

    /// Clear cache when files change (e.g. on refresh).
    func clearCache() {
        cache.removeAll()
    }

    func clearCache(for fileId: String) {
        cache.removeValue(forKey: fileId)
    }

    /// Remove background color attributes so the diff row's own background shows through.
    private static func stripBackgroundColor(from attr: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attr)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(.backgroundColor, range: fullRange)
        return mutable
    }

    // MARK: - Language Detection

    private func languageForFile(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return extensionToLanguage[ext]
        // Return nil to let highlight.js auto-detect
    }

    private let extensionToLanguage: [String: String] = [
        "swift": "swift",
        "m": "objectivec",
        "mm": "objectivec",
        "h": "objectivec",
        "c": "c",
        "cc": "cpp",
        "cpp": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "cs": "csharp",
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "go": "go",
        "rs": "rust",
        "py": "python",
        "rb": "ruby",
        "js": "javascript",
        "jsx": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "html": "xml",
        "htm": "xml",
        "xml": "xml",
        "css": "css",
        "scss": "scss",
        "less": "less",
        "json": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "ini",
        "ini": "ini",
        "cfg": "ini",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "fish": "bash",
        "ps1": "powershell",
        "sql": "sql",
        "md": "markdown",
        "markdown": "markdown",
        "r": "r",
        "R": "r",
        "lua": "lua",
        "pl": "perl",
        "pm": "perl",
        "php": "php",
        "ex": "elixir",
        "exs": "elixir",
        "erl": "erlang",
        "hs": "haskell",
        "scala": "scala",
        "dart": "dart",
        "groovy": "groovy",
        "gradle": "groovy",
        "tf": "hcl",
        "dockerfile": "dockerfile",
        "Dockerfile": "dockerfile",
        "makefile": "makefile",
        "Makefile": "makefile",
        "cmake": "cmake",
        "proto": "protobuf",
        "graphql": "graphql",
        "gql": "graphql",
        "vue": "xml",
        "svelte": "xml",
    ]
}
