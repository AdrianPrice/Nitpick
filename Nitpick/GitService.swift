import Foundation
import SwiftGitX

// MARK: - Git Service (libgit2-based via SwiftGitX)

/// Type alias to avoid collision between our model's Repository and SwiftGitX's Repository
private typealias GitRepo = SwiftGitX.Repository

actor GitService {
    enum GitError: Error, LocalizedError {
        case notAGitRepository
        case commandFailed(String)
        case stagingFailed(String)
        case commitFailed(String)
        case pushFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAGitRepository: return "Not a git repository"
            case .commandFailed(let msg): return "Git error: \(msg)"
            case .stagingFailed(let msg): return "Staging failed: \(msg)"
            case .commitFailed(let msg): return "Commit failed: \(msg)"
            case .pushFailed(let msg): return "Push failed: \(msg)"
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

                // Verify we can actually open this worktree (may fail under sandbox
                // if the worktree is outside the security-scoped resource)
                guard fm.isReadableFile(atPath: worktreePath) else { continue }
                let worktreeURL = URL(fileURLWithPath: worktreePath)
                guard (try? openRepo(at: worktreeURL)) != nil else { continue }

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

    // MARK: - Write Operations

    /// Ensures the repo-local git config has user.name and user.email set.
    /// This is needed because the App Sandbox prevents libgit2 from reading ~/.gitconfig.
    func ensureIdentity(name: String, email: String, worktreePath: String) throws {
        let url = URL(fileURLWithPath: worktreePath)

        // Find the .git directory (could be a file for worktrees pointing elsewhere)
        let gitPath = url.appendingPathComponent(".git")
        let configURL: URL

        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: gitPath.path, isDirectory: &isDir), isDir.boolValue {
            configURL = gitPath.appendingPathComponent("config")
        } else if fm.fileExists(atPath: gitPath.path) {
            // .git is a file (worktree) — read the actual gitdir path
            guard let content = try? String(contentsOf: gitPath, encoding: .utf8),
                  content.hasPrefix("gitdir: ") else {
                throw GitError.commandFailed("Cannot locate git config for worktree")
            }
            let gitdirPath = content.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "gitdir: ", with: "")
            // For worktrees, write to the shared repo config (parent)
            let gitdirURL = URL(fileURLWithPath: gitdirPath, relativeTo: url)
            // Go up from .git/worktrees/<name> to .git/config
            let repoGitDir = gitdirURL.deletingLastPathComponent().deletingLastPathComponent()
            configURL = repoGitDir.appendingPathComponent("config")
        } else {
            throw GitError.commandFailed("No .git directory found")
        }

        // Read existing config
        var config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        // Check if [user] section already has the values we need
        if config.contains("name = \(name)") && config.contains("email = \(email)") {
            return // Already configured
        }

        // Remove existing [user] section if present (we'll rewrite it)
        if let userRange = config.range(of: #"\[user\][^\[]*"#, options: .regularExpression) {
            config.removeSubrange(userRange)
        }

        // Append [user] section
        let userSection = "\n[user]\n\tname = \(name)\n\temail = \(email)\n"
        config.append(userSection)

        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Stage specific files by their relative paths (one at a time for reliability).
    func stageFiles(paths: [String], worktreePath: String) throws {
        let url = URL(fileURLWithPath: worktreePath)
        let repo = try openRepo(at: url)

        for path in paths {
            do {
                try repo.add(path: path)
            } catch {
                throw GitError.stagingFailed("\(path): \(error.message)")
            }
        }
    }

    /// Create a commit with the current index (staged files).
    @discardableResult
    func commit(message: String, worktreePath: String) throws -> String {
        let url = URL(fileURLWithPath: worktreePath)
        let repo = try openRepo(at: url)

        do {
            let commit = try repo.commit(message: message)
            return commit.id.hex
        } catch {
            throw GitError.commitFailed(error.message)
        }
    }

    /// Push current branch to the remote.
    func push(worktreePath: String) async throws {
        let url = URL(fileURLWithPath: worktreePath)
        let repo = try openRepo(at: url)

        do {
            try await repo.push()
        } catch {
            throw GitError.pushFailed(error.message)
        }
    }

    /// Check whether the current branch has an upstream configured (i.e. push is possible).
    /// Returns true if an upstream remote tracking branch exists.
    func hasUpstream(worktreePath: String) throws -> Bool {
        let url = URL(fileURLWithPath: worktreePath)
        let repo = try openRepo(at: url)

        do {
            let current = try repo.branch.current
            return (try? current.upstream) != nil
        } catch {
            return false
        }
    }

    /// Returns the current branch name and whether it has an upstream configured.
    func branchInfo(worktreePath: String) throws -> (name: String, hasUpstream: Bool) {
        let url = URL(fileURLWithPath: worktreePath)
        let repo = try openRepo(at: url)

        do {
            let current = try repo.branch.current
            let hasUpstream = (try? current.upstream) != nil
            return (name: current.name, hasUpstream: hasUpstream)
        } catch {
            return (name: "(detached)", hasUpstream: false)
        }
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
