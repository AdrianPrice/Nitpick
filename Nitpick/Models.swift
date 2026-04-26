import Foundation

// MARK: - Core Data Models

enum FileStatus: String, Hashable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"

    var label: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .untracked: return "Untracked"
        }
    }

    var symbol: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        case .untracked: return "questionmark.circle.fill"
        }
    }
}

enum DiffLineType: Hashable, Codable {
    case context
    case added
    case removed
}

struct DiffLine: Identifiable, Hashable, Codable {
    let id: UUID
    let type: DiffLineType
    let content: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    init(id: UUID = UUID(), type: DiffLineType, content: String, oldLineNumber: Int?, newLineNumber: Int?) {
        self.id = id
        self.type = type
        self.content = content
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiffLine, rhs: DiffLine) -> Bool {
        lhs.id == rhs.id
    }
}

struct DiffHunk: Identifiable {
    let id: String  // stable ID based on hunk position
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let header: String
    var lines: [DiffLine]

    init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String, lines: [DiffLine]) {
        self.id = "\(oldStart):\(oldCount):\(newStart):\(newCount)"
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.lines = lines
    }
}

struct DiffFile: Identifiable {
    let id: String  // stable ID based on file path
    let path: String
    let status: FileStatus
    let isBinary: Bool
    var hunks: [DiffHunk]

    init(path: String, status: FileStatus, hunks: [DiffHunk], isBinary: Bool = false) {
        self.id = path
        self.path = path
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
    }

    var allLines: [DiffLine] {
        hunks.flatMap(\.lines)
    }

    var addedCount: Int {
        hunks.flatMap(\.lines).filter { $0.type == .added }.count
    }

    var removedCount: Int {
        hunks.flatMap(\.lines).filter { $0.type == .removed }.count
    }

    /// A hash of the diff content, used to detect changes between refreshes.
    var diffContentHash: Int {
        var hasher = Hasher()
        for hunk in hunks {
            hasher.combine(hunk.header)
            for line in hunk.lines {
                hasher.combine(line.type)
                hasher.combine(line.content)
            }
        }
        return hasher.finalize()
    }
}

struct Worktree: Identifiable, Hashable {
    let id: String  // path-based stable ID
    let path: String
    let branch: String
    let isMain: Bool

    init(path: String, branch: String, isMain: Bool) {
        self.id = path
        self.path = path
        self.branch = branch
        self.isMain = isMain
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    static func == (lhs: Worktree, rhs: Worktree) -> Bool {
        lhs.path == rhs.path
    }

    var displayName: String {
        if branch.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return branch
    }
}

struct Repository {
    let path: String
    var worktrees: [Worktree]

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Diff Target

/// What the diff is comparing: working tree changes or a specific commit vs its parent.
enum DiffTarget: Hashable, Identifiable, Codable {
    case workingTree
    case commit(CommitInfo)

    var id: String {
        switch self {
        case .workingTree: return "working-tree"
        case .commit(let info): return info.id
        }
    }

    var displayName: String {
        switch self {
        case .workingTree: return "Uncommitted"
        case .commit(let info): return info.shortId + " " + info.summary
        }
    }

    var isWorkingTree: Bool {
        if case .workingTree = self { return true }
        return false
    }
}

/// Lightweight commit info, decoupled from SwiftGitX types.
struct CommitInfo: Hashable, Identifiable, Codable {
    let id: String        // full SHA hex
    let summary: String
    let message: String
    let date: Date
    let authorName: String

    var shortId: String { String(id.prefix(7)) }
}

// MARK: - Comment Model

struct LineComment: Identifiable, Codable {
    let id: UUID
    let fileId: String
    let lineIds: Set<UUID>        // all lines this comment covers
    let filePath: String
    let startLineNumber: Int?
    let endLineNumber: Int?
    let lineType: DiffLineType
    let lineContent: String       // first line's content (for display)
    var text: String
    let hunkContext: [DiffLine]   // all selected lines + surrounding context
    let diffTarget: DiffTarget    // which diff target this comment was made on

    init(
        id: UUID = UUID(),
        fileId: String,
        lineIds: Set<UUID>,
        filePath: String,
        startLineNumber: Int?,
        endLineNumber: Int?,
        lineType: DiffLineType,
        lineContent: String,
        text: String,
        hunkContext: [DiffLine],
        diffTarget: DiffTarget = .workingTree
    ) {
        self.id = id
        self.fileId = fileId
        self.lineIds = lineIds
        self.filePath = filePath
        self.startLineNumber = startLineNumber
        self.endLineNumber = endLineNumber
        self.lineType = lineType
        self.lineContent = lineContent
        self.text = text
        self.hunkContext = hunkContext
        self.diffTarget = diffTarget
    }
}
