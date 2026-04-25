import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State var state = AppState()
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
        } detail: {
            detailView
        }
        .navigationTitle(state.repository?.name ?? "Nitpick")
        .toolbar {
            toolbarContent
        }
        .overlay(alignment: .bottom) {
            if state.showCopiedToast {
                toastView
            }
        }
        .overlay {
            if state.isLoading {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .alert("Error", isPresented: .constant(state.errorMessage != nil)) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .alert("Clear Comments?", isPresented: $showClearConfirmation) {
            Button("Clear All", role: .destructive) { state.clearComments() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Remove all \(state.commentCount) comments? This cannot be undone.")
        }
        .sheet(isPresented: $state.showPromptPreview) {
            PromptPreviewSheet(state: state)
        }
        .onAppear {
            restoreLastRepo()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard state.repository != nil else { return }
            Task { await state.refreshDiff() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRepository)) { _ in
            openRepo()
        }
        .focusedSceneValue(\.appState, state)
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if let file = state.selectedFile {
            VStack(spacing: 0) {
                fileHeaderBar(file)
                Divider()

                switch state.diffViewMode {
                case .unified:
                    UnifiedDiffView(file: file, state: state)
                case .sideBySide:
                    SideBySideDiffView(file: file, state: state)
                }

                if state.commentCount > 0 {
                    commentActionBar
                }
            }
        } else if state.repository != nil {
            ContentUnavailableView(
                "Select a File",
                systemImage: "doc.text",
                description: Text("Choose a file from the sidebar to view its diff")
            )
        } else {
            welcomeView
        }
    }

    // MARK: - Welcome

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Open a Git Repository")
                .font(.title2)
            Text("Use File > Open or drag a repository folder here")
                .foregroundStyle(.secondary)
            Button("Open Repository...") {
                openRepo()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - File Header

    private func fileHeaderBar(_ file: DiffFile) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: file.status.symbol)
                    .foregroundStyle(statusColor(file.status))

                Text(file.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                Picker("View", selection: $state.diffViewMode) {
                    ForEach(DiffViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            HStack {
                let count = state.fileCommentCount(file.id)
                if count > 0 {
                    Label("\(count) comment\(count == 1 ? "" : "s")", systemImage: "bubble.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                let reviewed = state.isReviewed(file.id)
                Button {
                    state.toggleReviewed(file.id)
                } label: {
                    Label(
                        reviewed ? "Reviewed" : "Mark Reviewed",
                        systemImage: reviewed ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }
                .buttonStyle(.bordered)
                .tint(reviewed ? .green : nil)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Comment Action Bar

    private var commentActionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.blue)

            let files = state.commentedFileCount
            Text("\(state.commentCount) comment\(state.commentCount == 1 ? "" : "s") across \(files) file\(files == 1 ? "" : "s")")
                .font(.callout.weight(.medium))

            Spacer()

            Button {
                showClearConfirmation = true
            } label: {
                Text("Clear All")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                state.previewPrompt()
            } label: {
                Label("Preview", systemImage: "eye")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button {
                state.generatePrompt()
            } label: {
                Label("Copy Prompt", systemImage: "doc.on.clipboard")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: state.commentCount)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                openRepo()
            } label: {
                Label("Open Repository", systemImage: "folder")
            }
            .keyboardShortcut("o")
            .help("Open a different repository (Cmd+O)")

            Button {
                Task { await state.refreshDiff() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Refresh diffs (Cmd+R)")
        }
    }

    // MARK: - Toast

    private var toastView: some View {
        Text("Prompt copied to clipboard!")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.blue, in: Capsule())
            .shadow(radius: 4)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut, value: state.showCopiedToast)
    }

    // MARK: - Actions

    private func openRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository root directory"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await state.openRepository(at: url)
                saveLastRepo(url)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    Task { @MainActor in
                        await state.openRepository(at: url)
                        saveLastRepo(url)
                    }
                }
            }
        }
    }

    private func saveLastRepo(_ url: URL) {
        // Save a security-scoped bookmark so we can re-access this directory under sandbox
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "lastRepoBookmark")
        } catch {
            // Fallback: save path (won't work under sandbox on relaunch but keeps old behavior)
            UserDefaults.standard.set(url.path, forKey: "lastRepoPath")
        }
    }

    private func restoreLastRepo() {
        // Try bookmark first (sandbox-compatible)
        if let bookmarkData = UserDefaults.standard.data(forKey: "lastRepoBookmark") {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                UserDefaults.standard.removeObject(forKey: "lastRepoBookmark")
                return
            }

            guard url.startAccessingSecurityScopedResource() else { return }

            // If the bookmark was stale, re-save it
            if isStale {
                saveLastRepo(url)
            }

            Task { await state.openRepository(at: url) }
            return
        }

        // Legacy fallback: path-based (pre-sandbox)
        if let path = UserDefaults.standard.string(forKey: "lastRepoPath") {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                UserDefaults.standard.removeObject(forKey: "lastRepoPath")
                return
            }
            Task { await state.openRepository(at: url) }
        }
    }

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

// MARK: - Focused Value for keyboard shortcuts from menu

struct AppStateFocusedValueKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedValueKey.self] }
        set { self[AppStateFocusedValueKey.self] = newValue }
    }
}

#Preview {
    ContentView()
}
