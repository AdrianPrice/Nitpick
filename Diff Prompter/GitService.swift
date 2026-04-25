import Foundation

// MARK: - Git Service

actor GitService {
    enum GitError: Error, LocalizedError {
        case notAGitRepository
        case commandFailed(String)
        case gitNotFound

        var errorDescription: String? {
            switch self {
            case .notAGitRepository: return "Not a git repository"
            case .commandFailed(let msg): return "Git command failed: \(msg)"
            case .gitNotFound: return "git is not installed. Please install Xcode Command Line Tools by running: xcode-select --install"
            }
        }
    }

    /// Check whether git is available on this system.
    func checkGitAvailable() async -> Bool {
        do {
            _ = try await run(["--version"])
            return true
        } catch {
            return false
        }
    }

    private func run(_ arguments: [String], workingDirectory: String? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw GitError.gitNotFound
        }

        // Wait for termination without blocking the cooperative thread pool
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errString = String(data: errData, encoding: .utf8) ?? "Unknown error"
            if !errString.isEmpty {
                throw GitError.commandFailed(errString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        return String(data: outData, encoding: .utf8) ?? ""
    }

    // MARK: - Public API

    func isGitRepository(at path: String) async -> Bool {
        do {
            _ = try await run(["rev-parse", "--git-dir"], workingDirectory: path)
            return true
        } catch {
            return false
        }
    }

    func listWorktrees(repoPath: String) async throws -> [Worktree] {
        let output = try await run(["worktree", "list", "--porcelain"], workingDirectory: repoPath)
        return parseWorktreeList(output)
    }

    func currentBranch(worktreePath: String) async throws -> String {
        let output = try await run(["branch", "--show-current"], workingDirectory: worktreePath)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func diff(worktreePath: String) async throws -> String {
        return try await run(["diff", "HEAD"], workingDirectory: worktreePath)
    }

    func status(worktreePath: String) async throws -> [(String, FileStatus)] {
        let output = try await run(["status", "--porcelain"], workingDirectory: worktreePath)
        return parseStatus(output)
    }

    func untrackedFiles(worktreePath: String) async throws -> String {
        // Get diff of untracked files by adding them to diff with --no-index /dev/null
        // Actually, we handle untracked via status already. For diff content of untracked,
        // we'd need to read the file. For v1, we'll just show them in the file list.
        return ""
    }

    // MARK: - Parsing

    private func parseWorktreeList(_ output: String) -> [Worktree] {
        var worktrees: [Worktree] = []
        var currentPath: String?
        var currentBranch: String = ""
        var isBareBranch = false

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                if let path = currentPath {
                    worktrees.append(Worktree(
                        path: path,
                        branch: currentBranch,
                        isMain: worktrees.isEmpty
                    ))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = ""
                isBareBranch = false
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                // refs/heads/main -> main
                if ref.hasPrefix("refs/heads/") {
                    currentBranch = String(ref.dropFirst("refs/heads/".count))
                } else {
                    currentBranch = ref
                }
            } else if line == "bare" {
                isBareBranch = true
            } else if line.hasPrefix("HEAD ") {
                // detached HEAD
                if currentBranch.isEmpty {
                    currentBranch = "(detached)"
                }
            }
        }

        // Don't forget the last entry
        if let path = currentPath, !isBareBranch {
            worktrees.append(Worktree(
                path: path,
                branch: currentBranch,
                isMain: worktrees.isEmpty
            ))
        }

        return worktrees
    }

    private func parseStatus(_ output: String) -> [(String, FileStatus)] {
        var results: [(String, FileStatus)] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            guard line.count >= 3 else { continue }
            let worktreeStatus = line[line.index(line.startIndex, offsetBy: 1)]
            let pathPart = String(line.dropFirst(3))

            let statusChar: Character
            if worktreeStatus != " " && worktreeStatus != "?" {
                statusChar = worktreeStatus
            } else {
                statusChar = line[line.startIndex]
            }

            let status: FileStatus
            switch statusChar {
            case "A": status = .added
            case "M": status = .modified
            case "D": status = .deleted
            case "R": status = .renamed
            case "?": status = .untracked
            default: status = .modified
            }

            results.append((pathPart, status))
        }
        return results
    }
}
