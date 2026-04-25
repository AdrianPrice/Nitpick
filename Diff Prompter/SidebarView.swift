import SwiftUI

// MARK: - Sidebar: Worktree Picker + File List

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            worktreePicker
            Divider()
            fileFilterField
            Divider()
            fileList
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
        List(selection: Binding(
            get: { state.selectedFile?.id },
            set: { id in
                state.selectedFile = state.diffFiles.first { $0.id == id }
            }
        )) {
            ForEach(state.filteredFiles) { file in
                FileRow(file: file, commentCount: state.fileCommentCount(file.id))
                    .tag(file.id)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if state.diffFiles.isEmpty && !state.isLoading {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "checkmark.circle",
                    description: Text("Working tree is clean")
                )
            }
        }
    }
}

// MARK: - File Row

struct FileRow: View {
    let file: DiffFile
    let commentCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.status.symbol)
                .foregroundStyle(statusColor)
                .font(.system(size: 12))

            Text(file.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

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
