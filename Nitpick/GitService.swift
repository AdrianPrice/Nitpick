import Foundation
import SwiftGitX

// MARK: - Git Service (libgit2-based via SwiftGitX)

/// Type alias to avoid collision between our model's Repository and SwiftGitX's Repository
private typealias GitRepo = SwiftGitX.Repository

actor GitService {
    enum GitError: Error, LocalizedError {
        case notAGitRepository
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAGitRepository: return "Not a git repository"
            case .commandFailed(let msg): return "Git error: \(msg)"
            }
        }
    }

    // MARK: - Public API

    func isGitRepository(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        do {
            _ = try GitRepo.open(at: url)
            return true
        } catch {
            return false
        }
    }

    func listWorktrees(repoPath: String) throws -> [Worktree] {
        let url = URL(fileURLWithPath: repoPath)
        let repo = try openRepo(at: url)

        var worktrees: [Worktree] = []

        // The main worktree
        let mainBranch = branchName(for: repo)
        worktrees.append(Worktree(path: repoPath, branch: mainBranch, isMain: true))

        // Discover linked worktrees from .git/worktrees/
        let gitDir = url.appendingPathComponent(".git")
        let worktreesDir = gitDir.appendingPathComponent("worktrees")
        let fm = FileManager.default

        if fm.fileExists(atPath: worktreesDir.path) {
            let entries = (try? fm.contentsOfDirectory(atPath: worktreesDir.path)) ?? []
            for entry in entries {
                let entryDir = worktreesDir.appendingPathComponent(entry)
                let gitdirFile = entryDir.appendingPathComponent("gitdir")
                guard let gitdirContent = try? String(contentsOf: gitdirFile, encoding: .utf8) else { continue }

                let linkedPath = gitdirContent.trimmingCharacters(in: .whitespacesAndNewlines)
                let worktreePath = URL(fileURLWithPath: linkedPath).deletingLastPathComponent().path

                guard fm.fileExists(atPath: worktreePath) else { continue }

                // Get branch from HEAD file
                var branch = entry
                let headFile = entryDir.appendingPathComponent("HEAD")
                if let headContent = try? String(contentsOf: headFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) {
                    if headContent.hasPrefix("ref: refs/heads/") {
                        branch = String(headContent.dropFirst("ref: refs/heads/".count))
                    }
                }

                worktrees.append(Worktree(path: worktreePath, branch: branch, isMain: false))
            }
        }

        return worktrees
    }

    func diff(worktreePath: String) throws -> [DiffFile] {
        let url = URL(fileURLWithPath: worktreePath)
        let repo = try openRepo(at: url)

        // git diff HEAD — staged + unstaged changes vs HEAD
        let diff = try repo.diff(to: [.workingTree, .index])
        return convertDiff(diff)
    }

    func status(worktreePath: String) throws -> [(String, FileStatus)] {
        let url = URL(fileURLWithPath: worktreePath)
        let repo = try openRepo(at: url)

        let entries = try repo.status()
        var results: [(String, FileStatus)] = []

        for entry in entries {
            let path = entry.workingTree?.newFile.path ?? entry.index?.newFile.path ?? ""
            guard !path.isEmpty else { continue }

            let status = mapStatus(entry.status)
            results.append((path, status))
        }

        return results
    }

    /// Returns recent commits for the given worktree.
    func listCommits(worktreePath: String, limit: Int = 50) throws -> [CommitInfo] {
        let url = URL(fileURLWithPath: worktreePath)
        let repo = try openRepo(at: url)

        let commits = try repo.log(sorting: .time)
        var result: [CommitInfo] = []

        for commit in commits {
            result.append(CommitInfo(
                id: commit.id.hex,
                summary: commit.summary,
                message: commit.message,
                date: commit.date,
                authorName: commit.author.name
            ))
            if result.count >= limit { break }
        }

        return result
    }

    /// Returns the diff for a specific commit vs its parent.
    func diffCommit(worktreePath: String, commitId: String) throws -> [DiffFile] {
        let url = URL(fileURLWithPath: worktreePath)
        let repo = try openRepo(at: url)

        // Find the commit by walking the log (SwiftGitX doesn't expose lookup by OID directly)
        let commits = try repo.log(sorting: .time)
        var targetCommit: SwiftGitX.Commit?
        for commit in commits {
            if commit.id.hex == commitId {
                targetCommit = commit
                break
            }
        }

        guard let commit = targetCommit else {
            throw GitError.commandFailed("Commit \(commitId) not found")
        }

        let diff = try repo.diff(commit: commit)
        return convertDiff(diff)
    }

    // MARK: - Helpers

    private func openRepo(at url: URL) throws -> GitRepo {
        do {
            return try GitRepo.open(at: url)
        } catch {
            throw GitError.notAGitRepository
        }
    }

    private func branchName(for repo: GitRepo) -> String {
        do {
            let branch = try repo.branch.current
            return branch.name
        } catch {
            return "(detached)"
        }
    }

    private func mapStatus(_ statuses: [StatusEntry.Status]) -> FileStatus {
        // Check for untracked first (workingTreeNew without indexNew)
        if statuses.contains(.workingTreeNew) && !statuses.contains(.indexNew) {
            return .untracked
        }
        for s in statuses {
            switch s {
            case .indexNew, .workingTreeNew:
                return .added
            case .indexModified, .workingTreeModified:
                return .modified
            case .indexDeleted, .workingTreeDeleted:
                return .deleted
            case .indexRenamed, .workingTreeRenamed:
                return .renamed
            default:
                continue
            }
        }
        return .modified
    }

    // MARK: - Diff Conversion

    private func convertDiff(_ diff: SwiftGitX.Diff) -> [DiffFile] {
        var files: [DiffFile] = []

        for patch in diff.patches {
            let delta = patch.delta
            let filePath = delta.newFile.path
            let fileStatus = mapDeltaType(delta.type)
            let isBinary = delta.newFile.flags.contains(.binary) || delta.oldFile.flags.contains(.binary)

            var hunks: [DiffHunk] = []

            // Skip hunk parsing for binary files
            guard !isBinary else {
                files.append(DiffFile(path: filePath, status: fileStatus, hunks: [], isBinary: true))
                continue
            }

            for patchHunk in patch.hunks {
                var lines: [DiffLine] = []
                var oldLineNum = patchHunk.oldStart
                var newLineNum = patchHunk.newStart

                for patchLine in patchHunk.lines {
                    let lineType: DiffLineType
                    var oldNum: Int? = nil
                    var newNum: Int? = nil

                    switch patchLine.type {
                    case .context, .contextEOF:
                        lineType = .context
                        oldNum = oldLineNum
                        newNum = newLineNum
                        oldLineNum += 1
                        newLineNum += 1
                    case .addition, .additionEOF:
                        lineType = .added
                        newNum = newLineNum
                        newLineNum += 1
                    case .deletion, .deletionEOF:
                        lineType = .removed
                        oldNum = oldLineNum
                        oldLineNum += 1
                    }

                    // Strip trailing newline from content
                    var content = patchLine.content
                    if content.hasSuffix("\n") {
                        content = String(content.dropLast())
                    }

                    lines.append(DiffLine(
                        type: lineType,
                        content: content,
                        oldLineNumber: oldNum,
                        newLineNumber: newNum
                    ))
                }

                // Extract function context from hunk header
                let header = patchHunk.header.trimmingCharacters(in: .whitespacesAndNewlines)
                var headerContext = ""
                if let lastAt = header.range(of: "@@", options: .backwards,
                    range: header.index(header.startIndex, offsetBy: min(2, header.count))..<header.endIndex) {
                    headerContext = String(header[lastAt.upperBound...]).trimmingCharacters(in: .whitespaces)
                }

                hunks.append(DiffHunk(
                    oldStart: patchHunk.oldStart,
                    oldCount: patchHunk.oldLines,
                    newStart: patchHunk.newStart,
                    newCount: patchHunk.newLines,
                    header: headerContext,
                    lines: lines
                ))
            }

            files.append(DiffFile(
                path: filePath,
                status: fileStatus,
                hunks: hunks
            ))
        }

        return files
    }

    private func mapDeltaType(_ type: SwiftGitX.Diff.DeltaType) -> FileStatus {
        switch type {
        case .added: return .added
        case .deleted: return .deleted
        case .modified: return .modified
        case .renamed: return .renamed
        default: return .modified
        }
    }
}
