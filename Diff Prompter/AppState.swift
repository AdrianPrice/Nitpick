import Foundation
import SwiftUI
import Observation

// MARK: - App State

@MainActor
@Observable
final class AppState {
    var repository: Repository?
    var selectedWorktree: Worktree?
    var diffFiles: [DiffFile] = []
    var selectedFile: DiffFile?
    var comments: [LineComment] = []
    var isLoading = false
    var errorMessage: String?
    var showCopiedToast = false
    var showPromptPreview = false
    var previewPromptText = ""
    var fileFilter: String = ""
    var diffViewMode: DiffViewMode = .unified

    // Computed
    var filteredFiles: [DiffFile] {
        if fileFilter.isEmpty { return diffFiles }
        return diffFiles.filter { $0.path.localizedCaseInsensitiveContains(fileFilter) }
    }

    var commentCount: Int { comments.count }

    var commentedFileCount: Int {
        Set(comments.map(\.filePath)).count
    }

    func commentsForFile(_ fileId: UUID) -> [LineComment] {
        comments.filter { $0.fileId == fileId }
    }

    func commentForLine(_ lineId: UUID) -> LineComment? {
        comments.first { $0.lineIds.contains(lineId) }
    }

    func fileCommentCount(_ fileId: UUID) -> Int {
        comments.filter { $0.fileId == fileId }.count
    }

    private let gitService = GitService()

    // MARK: - Actions

    func openRepository(at url: URL) async {
        let path = url.path
        guard await gitService.isGitRepository(at: path) else {
            errorMessage = "Not a git repository: \(path)"
            return
        }

        do {
            let worktrees = try await gitService.listWorktrees(repoPath: path)
            repository = Repository(path: path, worktrees: worktrees)
            errorMessage = nil

            // Auto-select first worktree
            if let first = worktrees.first {
                selectWorktree(first)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectWorktree(_ worktree: Worktree) {
        selectedWorktree = worktree
        selectedFile = nil
        Task { await refreshDiff() }
    }

    func refreshDiff() async {
        guard let worktree = selectedWorktree else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            // Get diff and status in parallel
            async let diffOutput = gitService.diff(worktreePath: worktree.path)
            async let statusOutput = gitService.status(worktreePath: worktree.path)

            let diff = try await diffOutput
            let statuses = try await statusOutput

            var files = DiffParser.parse(diff)

            // Update file statuses from git status
            let statusMap = Dictionary(statuses, uniquingKeysWith: { first, _ in first })
            for i in files.indices {
                if let status = statusMap[files[i].path] {
                    files[i] = DiffFile(
                        path: files[i].path,
                        status: status,
                        hunks: files[i].hunks
                    )
                }
            }

            // Add untracked files that aren't in the diff
            let diffPaths = Set(files.map(\.path))
            for (path, status) in statuses where !diffPaths.contains(path) {
                files.append(DiffFile(path: path, status: status, hunks: []))
            }

            diffFiles = files.sorted { $0.path < $1.path }

            // Remap comments to new file/line UUIDs so they survive refresh
            remapCommentsToNewDiff()

            // If previously selected file is still present, keep it
            if let selected = selectedFile,
               let updated = diffFiles.first(where: { $0.path == selected.path }) {
                selectedFile = updated
            } else {
                selectedFile = diffFiles.first
            }

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addComment(on lines: [DiffLine], in file: DiffFile, hunkLines: [DiffLine], text: String) {
        guard let firstLine = lines.first else { return }
        let lastLine = lines.last ?? firstLine

        let startNum = firstLine.newLineNumber ?? firstLine.oldLineNumber
        let endNum = lastLine.newLineNumber ?? lastLine.oldLineNumber
        let lineIds = Set(lines.map(\.id))

        // Context: the selected lines plus a few surrounding lines
        let context = contextLines(for: lines, in: hunkLines)

        let comment = LineComment(
            fileId: file.id,
            lineIds: lineIds,
            filePath: file.path,
            startLineNumber: startNum,
            endLineNumber: endNum,
            lineType: firstLine.type,
            lineContent: firstLine.content,
            text: text,
            hunkContext: context
        )
        comments.append(comment)
    }

    func updateComment(_ commentId: UUID, text: String) {
        if let index = comments.firstIndex(where: { $0.id == commentId }) {
            comments[index].text = text
        }
    }

    func deleteComment(_ commentId: UUID) {
        comments.removeAll { $0.id == commentId }
    }

    func generatePrompt() {
        guard let repo = repository, let worktree = selectedWorktree else { return }
        let prompt = PromptGenerator.generate(
            repoName: repo.name,
            worktree: worktree,
            files: diffFiles,
            comments: comments
        )
        PromptGenerator.copyToClipboard(prompt)
        showCopiedToast = true

        // Auto-dismiss toast
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedToast = false
        }
    }

    func previewPrompt() {
        guard let repo = repository, let worktree = selectedWorktree else { return }
        previewPromptText = PromptGenerator.generate(
            repoName: repo.name,
            worktree: worktree,
            files: diffFiles,
            comments: comments
        )
        showPromptPreview = true
    }

    func copyPromptFromPreview() {
        PromptGenerator.copyToClipboard(previewPromptText)
        showPromptPreview = false
        showCopiedToast = true

        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedToast = false
        }
    }

    func clearComments() {
        comments.removeAll()
    }

    // Navigate to next/previous comment
    func nextComment() {
        guard !comments.isEmpty else { return }
        if let currentFile = selectedFile,
           let currentComment = comments.first(where: { $0.fileId == currentFile.id }),
           let idx = comments.firstIndex(where: { $0.id == currentComment.id }),
           idx + 1 < comments.count {
            let next = comments[idx + 1]
            selectedFile = diffFiles.first { $0.id == next.fileId }
        } else if let first = comments.first {
            selectedFile = diffFiles.first { $0.id == first.fileId }
        }
    }

    func previousComment() {
        guard !comments.isEmpty else { return }
        if let currentFile = selectedFile,
           let currentComment = comments.first(where: { $0.fileId == currentFile.id }),
           let idx = comments.firstIndex(where: { $0.id == currentComment.id }),
           idx > 0 {
            let prev = comments[idx - 1]
            selectedFile = diffFiles.first { $0.id == prev.fileId }
        }
    }

    // MARK: - Helpers

    private func remapCommentsToNewDiff() {
        // Build a lookup: filePath -> new DiffFile
        let filesByPath = Dictionary(diffFiles.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        comments = comments.compactMap { comment in
            guard let newFile = filesByPath[comment.filePath] else { return nil }
            let newAllLines = newFile.hunks.flatMap(\.lines)

            // Match each old line to a new line by (type, lineNumber, content)
            var newLineIds = Set<UUID>()
            // We need to match by line number and type. Build a lookup from old comment's line metadata.
            // Since we don't store per-line metadata for all lines, match by iterating new lines
            // and finding ones that correspond to the comment's line range.
            for newLine in newAllLines {
                let lineNum = newLine.newLineNumber ?? newLine.oldLineNumber
                guard let num = lineNum else { continue }
                let startNum = comment.startLineNumber ?? Int.min
                let endNum = comment.endLineNumber ?? Int.max
                if num >= startNum && num <= endNum && newLine.type == comment.lineType {
                    newLineIds.insert(newLine.id)
                }
                // Also match context lines in the range
                if num >= startNum && num <= endNum && comment.lineIds.count > 1 {
                    newLineIds.insert(newLine.id)
                }
            }

            // If single-line comment, try exact match on line number + type
            if comment.lineIds.count == 1, newLineIds.isEmpty {
                let targetNum = comment.startLineNumber
                for newLine in newAllLines {
                    let num = newLine.newLineNumber ?? newLine.oldLineNumber
                    if num == targetNum && newLine.type == comment.lineType {
                        newLineIds.insert(newLine.id)
                        break
                    }
                }
            }

            guard !newLineIds.isEmpty else { return nil }

            // Rebuild hunk context from the new file
            let newHunkContext: [DiffLine] = {
                for hunk in newFile.hunks {
                    if hunk.lines.contains(where: { newLineIds.contains($0.id) }) {
                        let matchedLines = hunk.lines.filter { newLineIds.contains($0.id) }
                        return contextLines(for: matchedLines, in: hunk.lines)
                    }
                }
                return []
            }()

            return LineComment(
                id: comment.id,
                fileId: newFile.id,
                lineIds: newLineIds,
                filePath: comment.filePath,
                startLineNumber: comment.startLineNumber,
                endLineNumber: comment.endLineNumber,
                lineType: comment.lineType,
                lineContent: comment.lineContent,
                text: comment.text,
                hunkContext: newHunkContext
            )
        }
    }

    private func contextLines(for lines: [DiffLine], in hunkLines: [DiffLine], radius: Int = 2) -> [DiffLine] {
        guard let firstLine = lines.first,
              let firstIdx = hunkLines.firstIndex(where: { $0.id == firstLine.id }) else {
            return lines
        }
        let lastLine = lines.last ?? firstLine
        let lastIdx = hunkLines.firstIndex(where: { $0.id == lastLine.id }) ?? firstIdx

        let start = max(0, firstIdx - radius)
        let end = min(hunkLines.count - 1, lastIdx + radius)
        return Array(hunkLines[start...end])
    }
}

enum DiffViewMode: String, CaseIterable {
    case unified = "Unified"
    case sideBySide = "Side by Side"
}
