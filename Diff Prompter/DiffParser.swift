import Foundation

// MARK: - Diff Parser

struct DiffParser {
    /// Parse unified diff output into an array of DiffFile objects
    static func parse(_ diffOutput: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var currentFilePath: String?
        var currentHunks: [DiffHunk] = []
        var currentLines: [DiffLine] = []
        var currentHunkHeader: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String)?
        var oldLineNum = 0
        var newLineNum = 0
        var fileStatus: FileStatus = .modified

        func flushHunk() {
            if let header = currentHunkHeader, !currentLines.isEmpty {
                currentHunks.append(DiffHunk(
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    header: header.header,
                    lines: currentLines
                ))
                currentLines = []
            }
        }

        func flushFile() {
            flushHunk()
            if let path = currentFilePath {
                files.append(DiffFile(
                    path: path,
                    status: fileStatus,
                    hunks: currentHunks
                ))
                currentHunks = []
                currentHunkHeader = nil
                fileStatus = .modified
            }
        }

        let lines = diffOutput.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // New file header: diff --git a/path b/path
            if line.hasPrefix("diff --git ") {
                flushFile()
                currentFilePath = parseFilePath(from: line)
                i += 1
                continue
            }

            // Detect new/deleted file markers
            if line.hasPrefix("new file mode") {
                fileStatus = .added
                i += 1
                continue
            }
            if line.hasPrefix("deleted file mode") {
                fileStatus = .deleted
                i += 1
                continue
            }

            // Skip --- and +++ headers
            if line.hasPrefix("---") || line.hasPrefix("+++") {
                i += 1
                continue
            }

            // Skip index, similarity, rename lines
            if line.hasPrefix("index ") || line.hasPrefix("similarity ") ||
               line.hasPrefix("rename ") || line.hasPrefix("old mode") ||
               line.hasPrefix("new mode") {
                i += 1
                continue
            }

            // Hunk header: @@ -oldStart,oldCount +newStart,newCount @@ optional context
            if line.hasPrefix("@@") {
                flushHunk()
                if let parsed = parseHunkHeader(line) {
                    currentHunkHeader = parsed
                    oldLineNum = parsed.oldStart
                    newLineNum = parsed.newStart
                }
                i += 1
                continue
            }

            // Diff content lines (only when we're inside a hunk)
            if currentHunkHeader != nil {
                if line.hasPrefix("+") {
                    currentLines.append(DiffLine(
                        type: .added,
                        content: String(line.dropFirst()),
                        oldLineNumber: nil,
                        newLineNumber: newLineNum
                    ))
                    newLineNum += 1
                } else if line.hasPrefix("-") {
                    currentLines.append(DiffLine(
                        type: .removed,
                        content: String(line.dropFirst()),
                        oldLineNumber: oldLineNum,
                        newLineNumber: nil
                    ))
                    oldLineNum += 1
                } else if line.hasPrefix(" ") {
                    currentLines.append(DiffLine(
                        type: .context,
                        content: String(line.dropFirst()),
                        oldLineNumber: oldLineNum,
                        newLineNumber: newLineNum
                    ))
                    oldLineNum += 1
                    newLineNum += 1
                } else if line.hasPrefix("\\") {
                    // "\ No newline at end of file" - skip
                    i += 1
                    continue
                }
            }

            i += 1
        }

        flushFile()
        return files
    }

    // MARK: - Helpers

    /// Extract file path from "diff --git a/path b/path"
    private static func parseFilePath(from line: String) -> String {
        // Format: diff --git a/file b/file
        // The two paths are always identical for non-rename diffs.
        // Since paths can contain " b/", we find the midpoint by matching the a/... b/... structure.
        let prefix = "diff --git a/"
        guard line.hasPrefix(prefix) else {
            return line.replacingOccurrences(of: "diff --git ", with: "")
        }
        let afterPrefix = String(line.dropFirst(prefix.count))
        // The format duplicates the path: "path b/path", so find " b/" followed by repeated suffix
        // Search from the end for " b/" to handle paths containing " b/"
        let searchTarget = " b/"
        var searchRange = afterPrefix.endIndex
        while let range = afterPrefix.range(of: searchTarget, options: .backwards, range: afterPrefix.startIndex..<searchRange) {
            let candidate = String(afterPrefix[range.upperBound...])
            let leftSide = String(afterPrefix[..<range.lowerBound])
            if candidate == leftSide {
                return candidate
            }
            searchRange = range.lowerBound
        }
        // Fallback: split on last " b/"
        if let range = afterPrefix.range(of: " b/", options: .backwards) {
            return String(afterPrefix[range.upperBound...])
        }
        return afterPrefix
    }

    /// Parse @@ -oldStart,oldCount +newStart,newCount @@ header
    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String)? {
        // Example: @@ -10,5 +10,7 @@ func foo()
        let pattern = #"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        func intGroup(_ i: Int) -> Int {
            guard let range = Range(match.range(at: i), in: line) else { return 1 }
            return Int(line[range]) ?? 1
        }

        let oldStart = intGroup(1)
        let oldCount = match.range(at: 2).location != NSNotFound ? intGroup(2) : 1
        let newStart = intGroup(3)
        let newCount = match.range(at: 4).location != NSNotFound ? intGroup(4) : 1
        let header: String
        if match.range(at: 5).location != NSNotFound, let range = Range(match.range(at: 5), in: line) {
            header = String(line[range]).trimmingCharacters(in: .whitespaces)
        } else {
            header = ""
        }

        return (oldStart, oldCount, newStart, newCount, header)
    }
}
