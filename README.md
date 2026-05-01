# Nitpick

A native macOS app for reviewing git diffs and generating structured AI prompts from your code review comments.

![macOS](https://img.shields.io/badge/macOS-26%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## What is Nitpick?

Nitpick bridges the gap between reading code and talking to AI. Instead of copying diffs and writing context by hand, you review changes visually, leave inline comments, and generate a structured prompt with one click.

It's built for solo developers who work with AI coding agents (Copilot, Claude, Cursor, etc.) and want a faster way to provide targeted feedback on code changes.

![til](./assets/demo.gif)

## Features

### Review Diffs
- View uncommitted changes or browse previous commits
- Unified and side-by-side diff views
- Syntax highlighting for 185+ languages
- Collapsible hunks to focus on what matters
- Full git worktree support

### Comment on Code
- Click or drag to select lines, then add inline comments
- Multi-line comments with Shift+Enter
- Comments persist across app launches
- Track review progress by marking files as reviewed

### Generate AI Prompts
- One click to generate a structured markdown prompt
- Comments grouped by commit and file with surrounding diff context
- Customizable preamble to set the tone for your AI agent
- Preview before copying to clipboard

### Native & Private
- Built with SwiftUI and libgit2 — no git CLI dependency
- All data stays on your machine
- No accounts, no telemetry, no network calls
- App Sandbox enabled

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Cmd+O | Open repository |
| Cmd+R | Refresh diff |
| Cmd+Shift+P | Preview prompt |
| Cmd+Shift+C | Copy prompt |
| Cmd+\ | Toggle unified/side-by-side |
| Cmd+] | Next comment |
| Cmd+[ | Previous comment |

## Building from Source

1. Clone the repository
2. Open `Nitpick.xcodeproj` in Xcode
3. Swift Package Manager will resolve dependencies automatically (SwiftGitX, HighlighterSwift)
4. Build and run (Cmd+R)

Requires Xcode 26+ and macOS 26+.

## Support

If you run into a bug or have a feature request, please [open an issue](https://github.com/AdrianPrice/Nitpick/issues/new).

See [SUPPORT.md](SUPPORT.md) for more details.

## License

MIT
