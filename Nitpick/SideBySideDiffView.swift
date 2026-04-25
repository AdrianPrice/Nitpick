import SwiftUI

// MARK: - Side-by-Side Diff View

struct SideBySideDiffView: View {
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

    private let coordSpace = "sideBySideDiffList"

    private var flatLines: [(line: DiffLine, hunkLines: [DiffLine])] {
        file.hunks.flatMap { hunk in
            hunk.lines.map { (line: $0, hunkLines: hunk.lines) }
        }
    }

    private var flatLineIds: [UUID] {
        flatLines.map(\.line.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(file.hunks) { hunk in
                        hunkHeaderView(hunk)

                        let pairs = buildSideBySidePairs(hunk.lines)
                        ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                            sideBySideRow(pair, hunkLines: hunk.lines)

                            if let left = pair.left, let comment = state.commentForLine(left.id),
                               isLastLineOfComment(line: left, comment: comment) {
                                inlineCommentView(comment)
                                    .id(comment.id)
                            }
                            if let right = pair.right, right.id != pair.left?.id,
                               let comment = state.commentForLine(right.id),
                               isLastLineOfComment(line: right, comment: comment) {
                                inlineCommentView(comment)
                                    .id(comment.id)
                            }

                            if let lastLine = commentingLines.last {
                                if (pair.left?.id == lastLine.id) || (pair.right?.id == lastLine.id) {
                                    commentEditorView()
                                }
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

            if let existingComment = lines.lazy.compactMap({ state.commentForLine($0.id) }).first {
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

    private func isFirstLineOfComment(line: DiffLine, comment: LineComment) -> Bool {
        let allLines = file.hunks.flatMap(\.lines)
        guard let firstInOrder = allLines.first(where: { comment.lineIds.contains($0.id) }) else { return false }
        return firstInOrder.id == line.id
    }

    private func isLastLineOfComment(line: DiffLine, comment: LineComment) -> Bool {
        let allLines = file.hunks.flatMap(\.lines)
        guard let lastInOrder = allLines.last(where: { comment.lineIds.contains($0.id) }) else { return false }
        return lastInOrder.id == line.id
    }

    // MARK: - Hunk Header

    private func hunkHeaderView(_ hunk: DiffHunk) -> some View {
        HStack {
            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.header)")
                .foregroundStyle(.secondary)
                .font(.system(.caption, design: .monospaced))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.08))
    }

    // MARK: - Side by Side Row

    private func sideBySideRow(_ pair: LinePair, hunkLines: [DiffLine]) -> some View {
        HStack(spacing: 0) {
            sideColumn(line: pair.left, isOld: true, hunkLines: hunkLines)
            Divider()
            sideColumn(line: pair.right, isOld: false, hunkLines: hunkLines)
        }
    }

    private func sideColumn(line: DiffLine?, isOld: Bool, hunkLines: [DiffLine]) -> some View {
        let isSelected = line.map { selectedLineIds.contains($0.id) } ?? false
        let existingComment = line.flatMap { state.commentForLine($0.id) }
        let isCommented = existingComment != nil
        let isFirstOfComment = isCommented && line != nil && isFirstLineOfComment(line: line!, comment: existingComment!)

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

            if let line {
                let lineNum = isOld ? line.oldLineNumber : line.newLineNumber
                Text(lineNum.map { String($0) } ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
                    .padding(.trailing, 4)

                Text(line.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.primary)

                if isFirstOfComment {
                    Image(systemName: "bubble.left.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(.trailing, 4)
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) :
            isCommented ? Color.blue.opacity(0.04) :
            sideBackground(line: line)
        )
        .contentShape(Rectangle())
        // Report geometry for the primary side only (left for context lines to avoid dupes)
        .modifier(line != nil && (line!.type != .context || isOld)
            ? ReportLineGeometryOptional(id: line!.id, coordinateSpaceName: coordSpace, store: geoStore, enabled: true)
            : ReportLineGeometryOptional(id: UUID(), coordinateSpaceName: coordSpace, store: geoStore, enabled: false)
        )
        .contextMenu {
            if let line {
                if state.commentForLine(line.id) == nil {
                    Button("Add Comment") { startCommenting(on: [line], hunkLines: hunkLines) }
                } else {
                    Button("Delete Comment") {
                        if let c = state.commentForLine(line.id) {
                            state.deleteComment(c.id)
                        }
                    }
                }
            }
        }
    }

    private func sideBackground(line: DiffLine?) -> Color {
        guard let line else { return Color.secondary.opacity(0.03) }
        switch line.type {
        case .added: return Color.green.opacity(0.1)
        case .removed: return Color.red.opacity(0.1)
        case .context: return .clear
        }
    }

    // MARK: - Comments

    private func inlineCommentView(_ comment: LineComment) -> some View {
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
                    .onSubmit { submitComment() }
            }

            Button("Save") { submitComment() }
                .keyboardShortcut(.return, modifiers: .command)

            Button("Cancel") { cancelCommenting() }
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

    // MARK: - Helpers

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

    // MARK: - Build Pairs

    struct LinePair {
        let left: DiffLine?
        let right: DiffLine?
    }

    private func buildSideBySidePairs(_ lines: [DiffLine]) -> [LinePair] {
        var pairs: [LinePair] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            switch line.type {
            case .context:
                pairs.append(LinePair(left: line, right: line))
                i += 1

            case .removed:
                var removed: [DiffLine] = []
                while i < lines.count && lines[i].type == .removed {
                    removed.append(lines[i])
                    i += 1
                }
                var added: [DiffLine] = []
                while i < lines.count && lines[i].type == .added {
                    added.append(lines[i])
                    i += 1
                }
                let maxCount = max(removed.count, added.count)
                for j in 0..<maxCount {
                    pairs.append(LinePair(
                        left: j < removed.count ? removed[j] : nil,
                        right: j < added.count ? added[j] : nil
                    ))
                }

            case .added:
                pairs.append(LinePair(left: nil, right: line))
                i += 1
            }
        }

        return pairs
    }
}

// MARK: - Conditional geometry reporting modifier

struct ReportLineGeometryOptional: ViewModifier {
    let id: UUID
    let coordinateSpaceName: String
    let store: LineGeometryStore
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.modifier(ReportLineGeometry(id: id, coordinateSpaceName: coordinateSpaceName, store: store))
        } else {
            content
        }
    }
}
