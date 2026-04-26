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

enum DiffLineType: Hashable {
    case context
    case added
    case removed
}

struct DiffLine: Identifiable, Hashable {
    let id = UUID()
    let type: DiffLineType
    let content: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiffLine, rhs: DiffLine) -> Bool {
        lhs.id == rhs.id
    }
}

struct DiffHunk: Identifiable {
    let id = UUID()
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let header: String
    var lines: [DiffLine]
}

struct DiffFile: Identifiable {
    let id: String  // stable ID based on file path
    let path: String
    let status: FileStatus
    var hunks: [DiffHunk]

    init(path: String, status: FileStatus, hunks: [DiffHunk]) {
        self.id = path
        self.path = path
        self.status = status
        self.hunks = hunks
    }

    var allLines: [DiffLine] {
        hunks.flatMap(\.lines)
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
    let id = UUID()
    let path: String
    let branch: String
    let isMain: Bool

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
enum DiffTarget: Hashable, Identifiable {
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
struct CommitInfo: Hashable, Identifiable {
    let id: String        // full SHA hex
    let summary: String
    let message: String
    let date: Date
    let authorName: String

    var shortId: String { String(id.prefix(7)) }
}

// MARK: - Comment Model

struct LineComment: Identifiable {
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
