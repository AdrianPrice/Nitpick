import SwiftUI

// MARK: - Mutable geometry storage for line hit-testing

@Observable
final class LineGeometryStore {
    var frames: [UUID: CGRect] = [:]

    func setFrame(_ frame: CGRect, for id: UUID) {
        frames[id] = frame
    }

    func lineIndex(at y: CGFloat, in flatLineIds: [UUID]) -> Int? {
        // First try exact hit
        for (i, id) in flatLineIds.enumerated() {
            if let frame = frames[id], y >= frame.minY && y <= frame.maxY {
                return i
            }
        }
        // Clamp: if above all lines, return first; below all, return last
        guard !flatLineIds.isEmpty else { return nil }
        if let firstFrame = frames[flatLineIds.first!], y < firstFrame.minY {
            return 0
        }
        if let lastFrame = frames[flatLineIds.last!], y > lastFrame.maxY {
            return flatLineIds.count - 1
        }
        // Closest midpoint
        var bestIdx = 0
        var bestDist: CGFloat = .infinity
        for (i, id) in flatLineIds.enumerated() {
            if let frame = frames[id] {
                let dist = abs(y - frame.midY)
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = i
                }
            }
        }
        return bestIdx
    }
}

// MARK: - Modifier to report geometry into the store

struct ReportLineGeometry: ViewModifier {
    let id: UUID
    let coordinateSpaceName: String
    let store: LineGeometryStore

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            store.setFrame(geo.frame(in: .named(coordinateSpaceName)), for: id)
                        }
                        .onChange(of: geo.frame(in: .named(coordinateSpaceName))) { _, newFrame in
                            store.setFrame(newFrame, for: id)
                        }
                }
            )
    }
}

// MARK: - Unified Diff View

struct UnifiedDiffView: View {
    let file: DiffFile
    @Bindable var state: AppState
    @State private var commentingLines: [DiffLine] = []
    @State private var commentingHunkLines: [DiffLine] = []
    @State private var commentText: String = ""

    @State private var isDragging = false
    @State private var dragAnchorIndex: Int?
    @State private var selectedLineIds: Set<UUID> = []
    @State private var geoStore = LineGeometryStore()
    @FocusState private var isCommentFieldFocused: Bool
    @State private var scrollTarget: UUID?
    @State private var highlightedCommentId: UUID?
    @State private var editingCommentId: UUID?
    @State private var editingCommentText: String = ""
    @FocusState private var isEditFieldFocused: Bool

    private var flatLines: [(line: DiffLine, hunkLines: [DiffLine])] {
        file.hunks.flatMap { hunk in
            hunk.lines.map { (line: $0, hunkLines: hunk.lines) }
        }
    }

    private var flatLineIds: [UUID] {
        flatLines.map(\.line.id)
    }

    private let coordSpace = "unifiedDiffList"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(file.hunks) { hunk in
                        hunkHeaderView(hunk)
                        ForEach(hunk.lines) { line in
                            diffLineView(line, hunkLines: hunk.lines)
                                .modifier(ReportLineGeometry(id: line.id, coordinateSpaceName: coordSpace, store: geoStore))
                            if let comment = state.commentForLine(line.id),
                               isLastLineOfComment(line: line, comment: comment) {
                                existingCommentView(comment)
                                    .id(comment.id)
                            }
                            if let lastCommentingLine = commentingLines.last,
                               lastCommentingLine.id == line.id {
                                commentEditorView()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .coordinateSpace(name: coordSpace)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(coordSpace))
                        .onChanged { value in handleDragChanged(value) }
                        .onEnded { _ in handleDragEnded() }
                )
            }
            .onChange(of: scrollTarget) { _, target in
                if let target {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    scrollTarget = nil
                }
            }
        }
        .font(.system(.body, design: .monospaced))
        .onChange(of: file.id) {
            geoStore.frames.removeAll()
            cancelCommenting()
        }
    }

    // MARK: - Drag handling

    private func handleDragChanged(_ value: DragGesture.Value) {
        let ids = flatLineIds
        guard !ids.isEmpty else { return }

        if !isDragging {
            isDragging = true
            dragAnchorIndex = geoStore.lineIndex(at: value.startLocation.y, in: ids)
        }

        guard let anchorIdx = dragAnchorIndex,
              let currentIdx = geoStore.lineIndex(at: value.location.y, in: ids) else { return }

        let range = min(anchorIdx, currentIdx)...max(anchorIdx, currentIdx)
        selectedLineIds = Set(ids[range])
    }

    private func handleDragEnded() {
        isDragging = false
        let flat = flatLines
        let orderedSelected = flat.filter { selectedLineIds.contains($0.line.id) }

        if let first = orderedSelected.first {
            let lines = orderedSelected.map(\.line)
            let hunkLines = first.hunkLines

            // Check if any selected line already has a comment
            if let existingComment = lines.lazy.compactMap({ state.commentForLine($0.id) }).first {
                // Scroll to and briefly highlight the existing comment
                selectedLineIds = []
                scrollTarget = existingComment.id
                highlightedCommentId = existingComment.id
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if highlightedCommentId == existingComment.id {
                        highlightedCommentId = nil
                    }
                }
            } else {
                startCommenting(on: lines, hunkLines: hunkLines)
            }
        } else {
            selectedLineIds = []
        }

        dragAnchorIndex = nil
    }

    // MARK: - Helpers for comment display

    private func isFirstLineOfComment(line: DiffLine, comment: LineComment) -> Bool {
        let allLines = file.hunks.flatMap(\.lines)
        guard let firstInOrder = allLines.first(where: { comment.lineIds.contains($0.id) }) else {
            return false
        }
        return firstInOrder.id == line.id
    }

    private func isLastLineOfComment(line: DiffLine, comment: LineComment) -> Bool {
        let allLines = file.hunks.flatMap(\.lines)
        guard let lastInOrder = allLines.last(where: { comment.lineIds.contains($0.id) }) else {
            return false
        }
        return lastInOrder.id == line.id
    }

    // MARK: - Hunk Header

    private func hunkHeaderView(_ hunk: DiffHunk) -> some View {
        HStack(spacing: 0) {
            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                .foregroundStyle(.secondary)
            if !hunk.header.isEmpty {
                Text(" \(hunk.header)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.08))
    }

    // MARK: - Diff Line

    private func diffLineView(_ line: DiffLine, hunkLines: [DiffLine]) -> some View {
        let isSelected = selectedLineIds.contains(line.id)
        let existingComment = state.commentForLine(line.id)
        let isCommented = existingComment != nil
        let isFirstOfComment = isCommented && isFirstLineOfComment(line: line, comment: existingComment!)

        return HStack(spacing: 0) {
            // Blue gutter indicator for commented lines
            if isCommented {
                Rectangle()
                    .fill(Color.blue.opacity(0.5))
                    .frame(width: 3)
            } else {
                Color.clear
                    .frame(width: 3)
            }

            lineNumberColumn(line.oldLineNumber)
            lineNumberColumn(line.newLineNumber)

            Text(linePrefix(line.type))
                .foregroundStyle(linePrefixColor(line.type))
                .frame(width: 14, alignment: .center)

            Text(line.content)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isFirstOfComment {
                Image(systemName: "bubble.left.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .padding(.trailing, 8)
            }
        }
        .padding(.trailing, 4)
        .padding(.vertical, 1)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) :
            isCommented ? Color.blue.opacity(0.04) :
            lineBackground(line.type)
        )
        .contentShape(Rectangle())
        .contextMenu {
            if !isCommented {
                Button("Add Comment") { startCommenting(on: [line], hunkLines: hunkLines) }
            } else {
                Button("Delete Comment") {
                    if let c = existingComment {
                        state.deleteComment(c.id)
                    }
                }
            }
        }
    }

    private func lineNumberColumn(_ number: Int?) -> some View {
        Text(number.map { String($0) } ?? "")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 4)
    }

    // MARK: - Comment Views

    private func existingCommentView(_ comment: LineComment) -> some View {
        let lineCount = comment.lineIds.count
        let rangeLabel: String = {
            if lineCount <= 1 { return "" }
            let start = comment.startLineNumber ?? 0
            let end = comment.endLineNumber ?? 0
            return "lines \(start)-\(end)"
        }()
        let isHighlighted = highlightedCommentId == comment.id
        let isEditing = editingCommentId == comment.id

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bubble.left.fill")
                .foregroundStyle(.blue)
                .font(.caption)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                if !rangeLabel.isEmpty {
                    Text(rangeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isEditing {
                    TextField("Edit comment...", text: $editingCommentText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($isEditFieldFocused)
                        .onSubmit { saveEditingComment(comment.id) }
                } else {
                    Text(comment.text)
                        .font(.system(.body))
                        .onTapGesture { startEditingComment(comment) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isEditing {
                Button("Save") { saveEditingComment(comment.id) }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { cancelEditingComment() }
                    .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button {
                    startEditingComment(comment)
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    state.deleteComment(comment.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.blue.opacity(0.2) : Color.blue.opacity(0.08))
        .overlay(
            Rectangle()
                .frame(width: 3)
                .foregroundStyle(.blue),
            alignment: .leading
        )
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
    }

    private func commentEditorView() -> some View {
        let lineCount = commentingLines.count

        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if lineCount > 1 {
                    Text("\(lineCount) lines selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Add a comment...", text: $commentText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isCommentFieldFocused)
                    .onSubmit {
                        submitComment()
                    }
            }

            Button("Save") {
                submitComment()
            }
            .keyboardShortcut(.return, modifiers: .command)

            Button("Cancel") {
                cancelCommenting()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.1))
        .overlay(
            Rectangle()
                .frame(width: 3)
                .foregroundStyle(.yellow),
            alignment: .leading
        )
    }

    // MARK: - Commenting Helpers

    private func startEditingComment(_ comment: LineComment) {
        editingCommentId = comment.id
        editingCommentText = comment.text
        Task { @MainActor in
            isEditFieldFocused = true
        }
    }

    private func saveEditingComment(_ commentId: UUID) {
        let trimmed = editingCommentText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            state.updateComment(commentId, text: trimmed)
        }
        cancelEditingComment()
    }

    private func cancelEditingComment() {
        editingCommentId = nil
        editingCommentText = ""
    }

    private func startCommenting(on lines: [DiffLine], hunkLines: [DiffLine]) {
        let anyCommented = lines.contains { state.commentForLine($0.id) != nil }
        if anyCommented { return }
        commentingLines = lines
        commentingHunkLines = hunkLines
        selectedLineIds = Set(lines.map(\.id))
        commentText = ""
        // Focus the text field on next run loop so the view is rendered first
        Task { @MainActor in
            isCommentFieldFocused = true
        }
    }

    private func submitComment() {
        guard !commentText.trimmingCharacters(in: .whitespaces).isEmpty,
              !commentingLines.isEmpty else { return }
        state.addComment(on: commentingLines, in: file, hunkLines: commentingHunkLines, text: commentText)
        cancelCommenting()
    }

    private func cancelCommenting() {
        commentingLines = []
        commentingHunkLines = []
        commentText = ""
        selectedLineIds = []
    }

    private func linePrefix(_ type: DiffLineType) -> String {
        switch type {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func lineBackground(_ type: DiffLineType) -> Color {
        switch type {
        case .added: return Color.green.opacity(0.1)
        case .removed: return Color.red.opacity(0.1)
        case .context: return .clear
        }
    }

    private func linePrefixColor(_ type: DiffLineType) -> Color {
        switch type {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }
}
