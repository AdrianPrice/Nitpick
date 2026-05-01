import SwiftUI

// MARK: - Sidebar: Worktree Picker + File List

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            worktreePicker
            Divider()
            commitPicker
            Divider()
            fileFilterField
            Divider()
            fileList

            if state.repository != nil && state.diffTarget.isWorkingTree {
                Divider()
                commitSection
            }
        }
        .frame(minWidth: 220)
    }

    // MARK: - Worktree Picker

    @ViewBuilder
    private var worktreePicker: some View {
        if let repo = state.repository {
            VStack(alignment: .leading, spacing: 6) {
                Text(repo.name)
                    .font(.headline)
                    .lineLimit(1)

                if repo.worktrees.count > 1 {
                    Picker("Worktree", selection: Binding(
                        get: { state.selectedWorktree },
                        set: { wt in
                            if let wt { state.selectWorktree(wt) }
                        }
                    )) {
                        ForEach(repo.worktrees) { wt in
                            Text(wt.displayName)
                                .tag(Optional(wt))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } else if let wt = state.selectedWorktree {
                    Label(wt.displayName, systemImage: "arrow.triangle.branch")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Commit Picker

    @ViewBuilder
    private var commitPicker: some View {
        if state.repository != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Diff Target")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Picker("Target", selection: Binding(
                    get: { state.diffTarget },
                    set: { state.selectDiffTarget($0) }
                )) {
                    Text("Uncommitted").tag(DiffTarget.workingTree)

                    if !state.recentCommits.isEmpty {
                        Divider()
                        ForEach(state.recentCommits) { commit in
                            Text("\(commit.shortId) \(commit.summary)")
                                .lineLimit(1)
                                .tag(DiffTarget.commit(commit))
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .id(state.recentCommits.map(\.id).hashValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - File Filter

    private var fileFilterField: some View {
        TextField("Filter files...", text: $state.fileFilter)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    // MARK: - File List

    private var fileList: some View {
        let tree = FileTreeNode.buildTree(
            from: state.filteredFiles,
            commentCounts: { state.fileCommentCount($0) }
        )
        return List(selection: Binding(
            get: { state.selectedFileId },
            set: { id in
                state.selectFile(state.diffFiles.first { $0.id == id })
            }
        )) {
            ForEach(tree.children) { node in
                FileTreeRow(node: node, state: state)
            }
        }
        .listStyle(.sidebar)
        .id("\(state.selectedWorktree?.path ?? "none"):\(state.diffTarget.id):\(state.filteredFiles.map(\.path).joined(separator: ",").hashValue)")
        .overlay {
            if state.diffFiles.isEmpty && !state.isLoading {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "checkmark.circle",
                    description: Text(state.diffTarget.isWorkingTree
                        ? "Working tree is clean"
                        : "No changes in this commit")
                )
            }
        }
    }

    // MARK: - Commit Section

    @ViewBuilder
    private var commitSection: some View {
        VStack(spacing: 8) {
            // Error banner
            if let error = state.commitPushError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button {
                        state.commitPushError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }

            // Commit message field
            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.commitMessage)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)

                if state.commitMessage.isEmpty {
                    Text("Commit message...")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 54)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            // Buttons
            HStack(spacing: 6) {
                if state.hasUpstream {
                    Button {
                        Task { await state.performPush() }
                    } label: {
                        if state.isPushing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Label("Push", systemImage: "arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.isPushing || state.isCommitting)
                }

                Spacer(minLength: 0)

                // File count label
                let count = state.diffFiles.count
                if count > 0 {
                    Text("\(count) file\(count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    state.selectedFilesForCommit = Set(state.diffFiles.map(\.path))
                    Task { await state.performCommit() }
                } label: {
                    if state.isCommitting {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.trailing, 2)
                        Text("Committing...")
                            .font(.caption)
                    } else {
                        Label("Commit", systemImage: "checkmark.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    state.isCommitting
                    || state.diffFiles.isEmpty
                    || state.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task {
            await state.refreshBranchInfo()
        }
    }
}

// MARK: - File Tree Model

struct FileTreeNode: Identifiable {
    let id: String // path component key for folders, file UUID string for files
    let name: String
    let file: DiffFile? // non-nil for leaf nodes
    let commentCount: Int
    var children: [FileTreeNode]

    var isFolder: Bool { file == nil }

    /// Builds a tree from a flat list of DiffFiles, collapsing single-child folders.
    static func buildTree(
        from files: [DiffFile],
        commentCounts: (String) -> Int
    ) -> FileTreeNode {
        var root = FileTreeNode(id: "root", name: "", file: nil, commentCount: 0, children: [])

        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            insert(
                components: components,
                file: file,
                commentCount: commentCounts(file.id),
                into: &root
            )
        }

        // Collapse single-child directories (e.g. "src/components" instead of "src" > "components")
        collapse(&root)

        return root
    }

    private static func insert(
        components: [String],
        file: DiffFile,
        commentCount: Int,
        into node: inout FileTreeNode
    ) {
        guard !components.isEmpty else { return }

        if components.count == 1 {
            // Leaf node — this is a file
            let leaf = FileTreeNode(
                id: file.id,
                name: components[0],
                file: file,
                commentCount: commentCount,
                children: []
            )
            node.children.append(leaf)
        } else {
            // Intermediate folder
            let folderName = components[0]
            if let idx = node.children.firstIndex(where: { $0.isFolder && $0.name == folderName }) {
                insert(
                    components: Array(components.dropFirst()),
                    file: file,
                    commentCount: commentCount,
                    into: &node.children[idx]
                )
            } else {
                var folder = FileTreeNode(
                    id: "folder:\(folderName):\(node.id)",
                    name: folderName,
                    file: nil,
                    commentCount: 0,
                    children: []
                )
                insert(
                    components: Array(components.dropFirst()),
                    file: file,
                    commentCount: commentCount,
                    into: &folder
                )
                node.children.append(folder)
            }
        }
    }

    /// Collapse folders that have a single child folder into "parent/child" combined nodes.
    private static func collapse(_ node: inout FileTreeNode) {
        // Recurse first
        for i in node.children.indices {
            collapse(&node.children[i])
        }

        // Collapse: if this folder has exactly one child and that child is also a folder
        for i in node.children.indices {
            while node.children[i].isFolder
                    && node.children[i].children.count == 1
                    && node.children[i].children[0].isFolder {
                let child = node.children[i].children[0]
                node.children[i] = FileTreeNode(
                    id: "folder:\(node.children[i].name)/\(child.name)",
                    name: "\(node.children[i].name)/\(child.name)",
                    file: nil,
                    commentCount: 0,
                    children: child.children
                )
            }
        }
    }
}

// MARK: - File Tree Row

struct FileTreeRow: View {
    let node: FileTreeNode
    let state: AppState
    @State private var isExpanded = true

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    FileTreeRow(node: child, state: state)
                }
            } label: {
                folderLabel
            }
        } else if let file = node.file {
            let reviewed = state.isReviewed(file.id)
            FileRow(file: file, fileName: node.name, commentCount: node.commentCount, isReviewed: reviewed)
                .tag(file.id)
                .contextMenu {
                    Button(reviewed ? "Mark as Unreviewed" : "Mark as Reviewed") {
                        state.toggleReviewed(file.id)
                    }
                }
        }
    }

    private var folderLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - File Row

struct FileRow: View {
    let file: DiffFile
    let fileName: String
    let commentCount: Int
    let isReviewed: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isReviewed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
            } else {
                Image(systemName: file.status.symbol)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 12))
            }

            Text(fileName)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            if file.addedCount > 0 || file.removedCount > 0 {
                HStack(spacing: 2) {
                    if file.addedCount > 0 {
                        Text("+\(file.addedCount)")
                            .foregroundStyle(.green)
                    }
                    if file.removedCount > 0 {
                        Text("-\(file.removedCount)")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption.monospacedDigit())
            }

            if commentCount > 0 {
                Text("\(commentCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.blue, in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .opacity(isReviewed ? 0.5 : 1.0)
    }

    private var statusColor: Color {
        switch file.status {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return .gray
        }
    }
}
