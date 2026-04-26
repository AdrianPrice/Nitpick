import Foundation
import AppKit

// MARK: - Prompt Generator

struct PromptGenerator {
    static func generate(
        repoName: String,
        worktree: Worktree,
        diffTarget: DiffTarget = .workingTree,
        files: [DiffFile],
        comments: [LineComment],
        preamble: String
    ) -> String {
        guard !comments.isEmpty else { return "" }

        var output = ""

        // Add preamble if non-empty
        let trimmedPreamble = preamble.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPreamble.isEmpty {
            output += "\(trimmedPreamble)\n\n---\n\n"
        }

        output += """
        Repository: \(repoName)
        Branch: \(worktree.branch)
        Files reviewed: \(files.count) | Comments: \(comments.count)

        ---

        """

        // Group comments by diff target, then by file
        let commentsByTarget = Dictionary(grouping: comments, by: { $0.diffTarget })
        let sortedTargets = commentsByTarget.keys.sorted { lhs, rhs in
            // Uncommitted first, then commits by their order
            if lhs.isWorkingTree { return true }
            if rhs.isWorkingTree { return false }
            return lhs.id < rhs.id
        }

        for target in sortedTargets {
            guard let targetComments = commentsByTarget[target] else { continue }

            // Section header for the diff target
            switch target {
            case .workingTree:
                output += "\n# Uncommitted changes\n"
            case .commit(let info):
                output += "\n# Commit: \(info.shortId) — \(info.summary)\n"
            }

            let commentsByFile = Dictionary(grouping: targetComments, by: { $0.filePath })
            let filesWithComments = commentsByFile.keys.sorted()

            for filePath in filesWithComments {
                guard let fileComments = commentsByFile[filePath]?.sorted(by: {
                    ($0.startLineNumber ?? 0) < ($1.startLineNumber ?? 0)
                }) else { continue }

                output += "\n## File: \(filePath)\n"

                for comment in fileComments {
                    let startLine = comment.startLineNumber ?? 0
                    let endLine = comment.endLineNumber ?? 0
                    let rangeStr = startLine == endLine ? "Line \(startLine)" : "Lines \(startLine)-\(endLine)"

                    let lineLabel: String
                    switch comment.lineType {
                    case .added:
                        lineLabel = "\(rangeStr) (added)"
                    case .removed:
                        lineLabel = "\(rangeStr) (removed)"
                    case .context:
                        lineLabel = rangeStr
                    }

                    output += "\n### \(lineLabel)\n"

                    // Include surrounding diff context
                    for contextLine in comment.hunkContext {
                        let prefix: String
                        switch contextLine.type {
                        case .added: prefix = "+ "
                        case .removed: prefix = "- "
                        case .context: prefix = "  "
                        }
                        output += "> \(prefix)\(contextLine.content)\n"
                    }

                    // Format comment — use blockquote for multi-line to keep it visually grouped
                    if comment.text.contains("\n") {
                        output += "\n**Comment:**\n"
                        for line in comment.text.components(separatedBy: "\n") {
                            output += "> \(line)\n"
                        }
                        output += "\n"
                    } else {
                        output += "\n**Comment:** \(comment.text)\n"
                    }
                }

                output += "\n---\n"
            }
        }

        return output
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
