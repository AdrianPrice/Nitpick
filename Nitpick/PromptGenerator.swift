import Foundation
import AppKit

// MARK: - Prompt Generator

struct PromptGenerator {
    static func generate(
        repoName: String,
        worktree: Worktree,
        files: [DiffFile],
        comments: [LineComment],
        preamble: String
    ) -> String {
        guard !comments.isEmpty else { return "" }

        let commentsByFile = Dictionary(grouping: comments, by: { $0.filePath })
        let filesWithComments = commentsByFile.keys.sorted()

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

        for filePath in filesWithComments {
            guard let fileComments = commentsByFile[filePath]?.sorted(by: {
                ($0.startLineNumber ?? 0) < ($1.startLineNumber ?? 0)
            }) else { continue }

            output += "\n## File: \(filePath)\n"

            for comment in fileComments {
                let lineLabel: String
                let startLine = comment.startLineNumber ?? 0
                let endLine = comment.endLineNumber ?? 0
                let rangeStr = startLine == endLine ? "Line \(startLine)" : "Lines \(startLine)-\(endLine)"

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

                output += "\nComment: \(comment.text)\n"
            }

            output += "\n---\n"
        }

        return output
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
