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
    var selectedFileId: String?
    var diffTarget: DiffTarget = .workingTree
    var recentCommits: [CommitInfo] = []
    var comments: [LineComment] = []
    var isLoading = false
    var errorMessage: String?
    var showCopiedToast = false
    var showPromptPreview = false
    var previewPromptText = ""
    var fileFilter: String = ""
    var diffViewMode: DiffViewMode = .unified
    var reviewedFileHashes: [String: Int] = [:]  // fileId -> diff content hash at review time
    var navigatedCommentId: UUID?  // set by next/previousComment, observed by diff views

    // Computed
    var filteredFiles: [DiffFile] {
        let filtered = fileFilter.isEmpty
            ? diffFiles
            : diffFiles.filter { $0.path.localizedCaseInsensitiveContains(fileFilter) }
        // Sort reviewed files to the bottom
        return filtered.sorted { lhs, rhs in
            let lReviewed = reviewedFileHashes[lhs.id] != nil
            let rReviewed = reviewedFileHashes[rhs.id] != nil
            if lReviewed != rReviewed { return !lReviewed }
            return false // preserve existing order within each group
        }
    }

    var commentCount: Int { comments.count }

    var commentedFileCount: Int {
        Set(comments.map(\.filePath)).count
    }

    var commentedTargetCount: Int {
        Set(comments.map(\.diffTarget)).count
    }

    func commentsForFile(_ fileId: String) -> [LineComment] {
        comments.filter { $0.fileId == fileId }
    }

    func commentForLine(_ lineId: UUID) -> LineComment? {
        comments.first { $0.lineIds.contains(lineId) }
    }

    func fileCommentCount(_ fileId: String) -> Int {
        comments.filter { $0.fileId == fileId && $0.diffTarget == diffTarget }.count
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
            loadComments()
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
        diffTarget = .workingTree
        recentCommits = []
        selectFile(nil)
        Task {
            await loadCommits()
            await refreshDiff()
        }
    }

    func selectDiffTarget(_ target: DiffTarget) {
        diffTarget = target
        selectFile(nil)
        reviewedFileHashes.removeAll()
        Task { await refreshDiff() }
    }

    func refreshDiff() async {
        guard let worktree = selectedWorktree else { return }
        isLoading = true
        defer { isLoading = false }

        // Refresh commit list so new commits appear in the picker
        await loadCommits()

        do {
            let files: [DiffFile]

            switch diffTarget {
            case .workingTree:
                // Get diff and status from libgit2
                let diffFiles = try await gitService.diff(worktreePath: worktree.path)
                let statuses = try await gitService.status(worktreePath: worktree.path)

                var merged = diffFiles

                // Update file statuses from status output (status may have more detail)
                let statusMap = Dictionary(statuses, uniquingKeysWith: { first, _ in first })
                for i in merged.indices {
                    if let status = statusMap[merged[i].path] {
                        merged[i] = DiffFile(
                            path: merged[i].path,
                            status: status,
                            hunks: merged[i].hunks
                        )
                    }
                }

                // Add files from status that aren't in the diff (e.g. untracked)
                // Read file content to create a synthetic "all added" diff
                let diffPaths = Set(merged.map(\.path))
                for (path, status) in statuses where !diffPaths.contains(path) {
                    let hunks = Self.syntheticHunks(
                        forFileAt: path,
                        relativeTo: worktree.path
                    )
                    merged.append(DiffFile(path: path, status: status, hunks: hunks))
                }

                files = merged.sorted { $0.path < $1.path }

            case .commit(let info):
                let diffFiles = try await gitService.diffCommit(worktreePath: worktree.path, commitId: info.id)
                files = diffFiles.sorted { $0.path < $1.path }
            }

            self.diffFiles = files

            // Unmark reviewed files whose diff content has changed
            for file in self.diffFiles {
                if let savedHash = reviewedFileHashes[file.id],
                   savedHash != file.diffContentHash {
                    reviewedFileHashes.removeValue(forKey: file.id)
                }
            }
            // Also remove reviewed entries for files no longer in the diff
            let currentIds = Set(self.diffFiles.map(\.id))
            reviewedFileHashes = reviewedFileHashes.filter { currentIds.contains($0.key) }

            // Remap comments to new file/line UUIDs so they survive refresh
            remapCommentsToNewDiff()
            saveComments()

            // Update selectedFile to the new instance (ID is stable, based on path)
            if let currentId = selectedFileId,
               let updated = self.diffFiles.first(where: { $0.id == currentId }) {
                selectedFile = updated
            } else {
                selectFile(self.diffFiles.first)
            }

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCommits() async {
        guard let worktree = selectedWorktree else { return }
        do {
            recentCommits = try await gitService.listCommits(worktreePath: worktree.path)
        } catch {
            recentCommits = []
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
            hunkContext: context,
            diffTarget: diffTarget
        )
        comments.append(comment)
        saveComments()
    }

    func updateComment(_ commentId: UUID, text: String) {
        if let index = comments.firstIndex(where: { $0.id == commentId }) {
            comments[index].text = text
        }
        saveComments()
    }

    func deleteComment(_ commentId: UUID) {
        comments.removeAll { $0.id == commentId }
        saveComments()
    }

    private var preamble: String {
        UserDefaults.standard.string(forKey: "promptPreamble") ?? PromptPreamble.defaultText
    }

    func generatePrompt() {
        guard let repo = repository, let worktree = selectedWorktree else { return }
        let prompt = PromptGenerator.generate(
            repoName: repo.name,
            worktree: worktree,
            diffTarget: diffTarget,
            files: diffFiles,
            comments: comments,
            preamble: preamble
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
        refreshPreviewText()
        showPromptPreview = true
    }

    func refreshPreviewText() {
        guard let repo = repository, let worktree = selectedWorktree else { return }
        previewPromptText = PromptGenerator.generate(
            repoName: repo.name,
            worktree: worktree,
            diffTarget: diffTarget,
            files: diffFiles,
            comments: comments,
            preamble: preamble
        )
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
        saveComments()
    }

    func toggleReviewed(_ fileId: String) {
        if reviewedFileHashes[fileId] != nil {
            reviewedFileHashes.removeValue(forKey: fileId)
        } else if let file = diffFiles.first(where: { $0.id == fileId }) {
            reviewedFileHashes[fileId] = file.diffContentHash
        }
    }

    func isReviewed(_ fileId: String) -> Bool {
        reviewedFileHashes[fileId] != nil
    }

    // Navigate to next/previous comment
    func nextComment() {
        let sorted = commentsSortedForNavigation()
        guard !sorted.isEmpty else { return }

        // Find the current position: navigatedCommentId, or first comment in current file
        let currentIdx: Int?
        if let navId = navigatedCommentId {
            currentIdx = sorted.firstIndex(where: { $0.id == navId })
        } else if let file = selectedFile {
            currentIdx = sorted.firstIndex(where: { $0.fileId == file.id }).map { $0 - 1 }
        } else {
            currentIdx = nil
        }

        let nextIdx = (currentIdx.map { $0 + 1 } ?? 0)
        guard nextIdx < sorted.count else { return }

        let comment = sorted[nextIdx]
        if selectedFile?.id != comment.fileId {
            selectFile(diffFiles.first { $0.id == comment.fileId })
        }
        navigatedCommentId = comment.id
    }

    func previousComment() {
        let sorted = commentsSortedForNavigation()
        guard !sorted.isEmpty else { return }

        let currentIdx: Int?
        if let navId = navigatedCommentId {
            currentIdx = sorted.firstIndex(where: { $0.id == navId })
        } else if let file = selectedFile {
            currentIdx = sorted.lastIndex(where: { $0.fileId == file.id }).map { $0 + 1 }
        } else {
            currentIdx = nil
        }

        let prevIdx = (currentIdx.map { $0 - 1 } ?? sorted.count - 1)
        guard prevIdx >= 0 else { return }

        let comment = sorted[prevIdx]
        if selectedFile?.id != comment.fileId {
            selectFile(diffFiles.first { $0.id == comment.fileId })
        }
        navigatedCommentId = comment.id
    }

    private func commentsSortedForNavigation() -> [LineComment] {
        let fileOrder = Dictionary(diffFiles.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { f, _ in f })
        return comments.sorted {
            let f0 = fileOrder[$0.fileId] ?? Int.max
            let f1 = fileOrder[$1.fileId] ?? Int.max
            if f0 != f1 { return f0 < f1 }
            return ($0.startLineNumber ?? 0) < ($1.startLineNumber ?? 0)
        }
    }

    /// Central selection method — keeps selectedFile and selectedFileId in sync.
    func selectFile(_ file: DiffFile?) {
        selectedFile = file
        selectedFileId = file?.id
    }

    // MARK: - Helpers

    private func remapCommentsToNewDiff() {
        // Build a lookup: filePath -> new DiffFile
        let filesByPath = Dictionary(diffFiles.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        comments = comments.compactMap { comment in
            // If this comment's file isn't in the current diff, preserve it as-is
            // (e.g. comment from a different commit's diff)
            guard let newFile = filesByPath[comment.filePath] else { return comment }
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

            guard !newLineIds.isEmpty else { return comment }

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
                hunkContext: newHunkContext,
                diffTarget: comment.diffTarget
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

    /// Read file content and create a synthetic "all added" hunk for untracked/new files.
    private static func syntheticHunks(forFileAt relativePath: String, relativeTo root: String) -> [DiffHunk] {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let fileLines = content.components(separatedBy: "\n")
        // Drop trailing empty element from trailing newline
        let trimmed = fileLines.last == "" ? Array(fileLines.dropLast()) : fileLines

        guard !trimmed.isEmpty else { return [] }

        let diffLines = trimmed.enumerated().map { idx, text in
            DiffLine(type: .added, content: text, oldLineNumber: nil, newLineNumber: idx + 1)
        }

        return [DiffHunk(
            oldStart: 0,
            oldCount: 0,
            newStart: 1,
            newCount: trimmed.count,
            header: "(new file)",
            lines: diffLines
        )]
    }

    // MARK: - Comment Persistence

    private var commentsFileURL: URL? {
        guard let repoPath = repository?.path else { return nil }
        let hash = repoPath.data(using: .utf8)!.map { String(format: "%02x", $0) }.joined().suffix(16)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Nitpick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("comments-\(hash).json")
    }

    func saveComments() {
        guard let url = commentsFileURL else { return }
        do {
            let data = try JSONEncoder().encode(comments)
            try data.write(to: url, options: .atomic)
        } catch {
            // Silent failure — persistence is best-effort
        }
    }

    func loadComments() {
        guard let url = commentsFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            comments = try JSONDecoder().decode([LineComment].self, from: data)
        } catch {
            // If file is corrupted, start fresh
            comments = []
        }
    }
}

enum DiffViewMode: String, CaseIterable {
    case unified = "Unified"
    case sideBySide = "Side by Side"
}
