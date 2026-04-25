import SwiftUI

@main
struct NitpickApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository...") {
                    NotificationCenter.default.post(name: .openRepository, object: nil)
                }
                .keyboardShortcut("o")
            }

            ReviewCommands()
        }
    }
}

// MARK: - Review Menu Commands

struct ReviewCommands: Commands {
    @FocusedValue(\.appState) private var state

    var body: some Commands {
        CommandMenu("Review") {
            Button("Refresh Diffs") {
                guard let state else { return }
                Task { await state.refreshDiff() }
            }
            .keyboardShortcut("r")
            .disabled(state?.repository == nil)

            Divider()

            Button("Preview Prompt") {
                state?.previewPrompt()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(state == nil || state!.commentCount == 0)

            Button("Copy Prompt") {
                state?.generatePrompt()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(state == nil || state!.commentCount == 0)

            Divider()

            Button("Toggle Unified / Side-by-Side") {
                guard let state else { return }
                state.diffViewMode = state.diffViewMode == .unified ? .sideBySide : .unified
            }
            .keyboardShortcut("\\")
            .disabled(state?.selectedFile == nil)

            Divider()

            Button("Next Comment") {
                state?.nextComment()
            }
            .keyboardShortcut("]")
            .disabled(state == nil || state!.commentCount == 0)

            Button("Previous Comment") {
                state?.previousComment()
            }
            .keyboardShortcut("[")
            .disabled(state == nil || state!.commentCount == 0)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openRepository = Notification.Name("openRepository")
}
