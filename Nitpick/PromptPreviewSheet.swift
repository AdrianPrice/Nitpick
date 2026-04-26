import SwiftUI

struct PromptPreviewSheet: View {
    @Bindable var state: AppState
    var onCopied: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Prompt Preview")
                    .font(.headline)

                Spacer()

                Text("\(state.commentCount) comment\(state.commentCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Prompt content
            ScrollView {
                Text(state.previewPromptText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            Divider()

            // Actions
            HStack {
                Button("Close") {
                    state.showPromptPreview = false
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Copy to Clipboard") {
                    state.copyPromptFromPreview()
                    onCopied()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 600, idealWidth: 800, minHeight: 400, idealHeight: 600)
    }
}
