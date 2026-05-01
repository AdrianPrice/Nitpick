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

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("promptPreamble") private var preamble = PromptPreamble.defaultText
    @AppStorage("gitAuthorName") private var gitName = ""
    @AppStorage("gitAuthorEmail") private var gitEmail = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Used for commit author/committer identity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Name", text: $gitName, prompt: Text("Your Name"))
                    TextField("Email", text: $gitEmail, prompt: Text("you@example.com"))
                }
            } header: {
                Text("Git Identity")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This text is prepended to every generated prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $preamble)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)

                    HStack {
                        Spacer()
                        Button("Reset to Default") {
                            preamble = PromptPreamble.defaultText
                        }
                    }
                }
            } header: {
                Text("Prompt Preamble")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 380)
    }
}

enum PromptPreamble {
    static let defaultText = """
        I've reviewed the changes and left some comments below. Please go through each comment carefully. For issues you agree with, implement the fix. For those you disagree with, explain your reasoning so we can discuss.
        """
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
