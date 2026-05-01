import SwiftUI

struct CommitSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if state.diffFiles.isEmpty && state.lastCommitSucceeded {
                postCommitView
            } else {
                commitFormView
            }
        }
        .frame(minWidth: 520, maxWidth: 520, minHeight: 400)
        .onAppear {
            isMessageFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Commit & Push")
                    .font(.headline)
                if !state.currentBranchName.isEmpty {
                    Label(state.currentBranchName, systemImage: "arrow.triangle.branch")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Commit Form

    private var commitFormView: some View {
        VStack(spacing: 0) {
            // File selection
            fileSelectionSection
            Divider()

            // Commit message
            commitMessageSection
            Divider()

            // Actions
            actionBar
        }
    }

    // MARK: - Post-Commit View (shows push option)

    private var postCommitView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Commit Successful")
                .font(.title2.weight(.medium))

            Text("All changes have been committed.")
                .foregroundStyle(.secondary)

            if state.hasUpstream {
                Button {
                    Task { await state.performPush() }
                } label: {
                    if state.isPushing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                        Text("Pushing...")
                    } else {
                        Label("Push to Remote", systemImage: "arrow.up.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isPushing)
                .controlSize(.large)
            } else {
                Text("No upstream branch configured. Push manually to set up tracking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let error = state.commitPushError {
                errorBanner(error)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - File Selection

    private var fileSelectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                let allSelected = state.selectedFilesForCommit.count == state.diffFiles.count
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        state.selectedFilesForCommit.removeAll()
                    } else {
                        state.selectedFilesForCommit = Set(state.diffFiles.map(\.path))
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(state.diffFiles) { file in
                        fileRow(file)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: 150)
        }
    }

    private func fileRow(_ file: DiffFile) -> some View {
        let isSelected = state.selectedFilesForCommit.contains(file.path)

        return Button {
            if isSelected {
                state.selectedFilesForCommit.remove(file.path)
            } else {
                state.selectedFilesForCommit.insert(file.path)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.system(size: 14))

                Image(systemName: file.status.symbol)
                    .foregroundStyle(statusColor(file.status))
                    .font(.system(size: 11))

                Text(file.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

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
                .font(.caption2.monospacedDigit())
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Commit Message

    private var commitMessageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Commit Message")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            TextEditor(text: $state.commitMessage)
                .font(.system(.body, design: .monospaced))
                .focused($isMessageFocused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if state.commitMessage.isEmpty {
                        Text("Summary of changes...")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 80, maxHeight: 120)
                .padding(.horizontal, 12)

            // Character count hint for summary line
            let firstLine = state.commitMessage.components(separatedBy: "\n").first ?? ""
            if firstLine.count > 50 {
                Text("Summary line is \(firstLine.count) characters (recommended: 50 or fewer)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        VStack(spacing: 8) {
            if let error = state.commitPushError {
                errorBanner(error)
            }

            HStack {
                let count = state.selectedFilesForCommit.count
                Text("\(count) file\(count == 1 ? "" : "s") selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if state.hasUpstream {
                    Button {
                        Task { await state.performPush() }
                    } label: {
                        if state.isPushing {
                            ProgressView()
                                .controlSize(.mini)
                                .padding(.trailing, 2)
                            Text("Pushing...")
                        } else {
                            Label("Push", systemImage: "arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isPushing || state.isCommitting)
                }

                Button {
                    Task { await state.performCommit() }
                } label: {
                    if state.isCommitting {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.trailing, 2)
                        Text("Committing...")
                    } else {
                        Label("Commit", systemImage: "checkmark.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    state.isCommitting
                    || state.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || state.selectedFilesForCommit.isEmpty
                )
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                state.commitPushError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 16)
    }

    // MARK: - Helpers

    private func statusColor(_ status: FileStatus) -> Color {
        switch status {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return .gray
        }
    }
}
