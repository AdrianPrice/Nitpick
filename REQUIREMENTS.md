# Diff Prompter - Requirements Document

## Overview

Diff Prompter is a native macOS app for solo developers working with AI coding agents. It lets you review git diffs across worktrees, annotate them with comments, and generate a structured prompt to feed back into an AI agent. The core workflow is: open a repo, pick a worktree, review diffs, leave comments, copy the resulting prompt.

---

## 1. User Profile

- **Target:** Solo developer reviewing AI-generated code changes
- **Platform:** macOS (SwiftUI native)
- **Workflow:** Review changes in git worktrees, annotate issues, generate AI prompts from annotations

---

## 2. Core Features

### 2.1 Repository & Worktree Management

| Requirement | Detail |
|---|---|
| Open a git repository | User selects a repo root directory via file picker or drag-and-drop |
| Auto-discover worktrees | On opening a repo, scan and list all `git worktree` entries automatically |
| Single worktree view | Display one worktree at a time; provide a sidebar or picker to switch between worktrees |
| Remember last repo | Persist the last-opened repo path across app launches for quick re-open |
| Worktree metadata | Show branch name, path, and dirty/clean status for each worktree in the list |

### 2.2 Diff Viewing

| Requirement | Detail |
|---|---|
| Comparison target | Working tree vs HEAD (uncommitted changes) |
| File list | Show all changed files in a sidebar/list with add/modify/delete indicators |
| Diff display - unified | Inline unified diff view (default) |
| Diff display - side-by-side | Old and new content side by side |
| Toggle view mode | User can switch between unified and side-by-side per file or globally |
| Diff coloring | Red background for removed lines, green background for added lines, neutral for context |
| No syntax highlighting (v1) | Basic diff coloring only; no language-aware syntax highlighting |
| File navigation | Click a file in the list to jump to its diff |
| Collapse/expand hunks | Allow collapsing individual diff hunks to reduce noise |
| Refresh | Manual refresh button + auto-refresh on window focus to pick up new changes |

### 2.3 Commenting

| Requirement | Detail |
|---|---|
| Line-level comments | Click on any diff line (added, removed, or context) to attach a free-text comment |
| Comment editing | Edit or delete existing comments inline |
| Comment visibility | Comments appear as inline annotations next to the relevant line in the diff view |
| Comment indicators | Files with comments show a badge/count in the file list |
| Comment scope | Comments are per-worktree, per-review session |
| Ephemeral | Comments are not persisted to disk; they exist only for the current session and are cleared after prompt generation (with confirmation) |
| No categorization (v1) | Free text only, no labels or priority levels |

### 2.4 Prompt Generation

| Requirement | Detail |
|---|---|
| Trigger | Explicit "Generate Prompt" button |
| Output | Copies formatted prompt to system clipboard |
| Confirmation | Show a brief confirmation toast/banner after copying |
| Structure per comment | File path, line number, the comment text, and surrounding diff context (added/removed lines from the hunk) |
| Prompt header | Include repo name, branch/worktree name, and total file/comment count as context |
| Ordering | Comments ordered by file path, then by line number |
| Clear after generate | Prompt user to clear all comments after successful generation (optional, not forced) |

**Example prompt output:**

```
Repository: my-project
Branch: feature/add-auth (worktree: /path/to/worktree)
Files reviewed: 4 | Comments: 7

---

## File: Sources/Auth/LoginService.swift

### Line 42 (added)
> + let token = try await fetchToken(user)
> + let session = Session(token: token)

Comment: This doesn't handle the case where fetchToken throws a network error. Add a retry or surface the error to the caller.

### Line 78 (removed)
> - guard let user = currentUser else { return }

Comment: Why was this guard removed? The nil case still needs handling below.

---

## File: Tests/AuthTests/LoginTests.swift

### Line 15 (added)
> + func testLoginSuccess() async throws {

Comment: Add a corresponding testLoginFailure case.

---
```

---

## 3. Navigation & UX

| Requirement | Detail |
|---|---|
| Layout | Three-column: worktree/file list (left), diff view (center), comment detail (right, collapsible) |
| Keyboard navigation | Arrow keys to move between files, Enter to open, Escape to close comment editor |
| Keyboard shortcut - comment | `Cmd+K` or similar to start a comment on the selected line |
| Keyboard shortcut - generate | `Cmd+Shift+C` to generate and copy prompt |
| Keyboard shortcut - refresh | `Cmd+R` to refresh diffs |
| Keyboard shortcut - toggle view | `Cmd+\` to toggle unified/side-by-side |
| Worktree switching | Sidebar list or dropdown; single click to switch |
| Search/filter files | Filter the file list by name |
| Jump between comments | Next/previous comment navigation (`Cmd+]` / `Cmd+[`) |

---

## 4. Technical Requirements

### 4.1 Stack

- **Language:** Swift
- **UI Framework:** SwiftUI (macOS 14+ / Sonoma minimum)
- **Architecture:** MVVM
- **Git interaction:** Shell out to `git` CLI (not libgit2) for simplicity and reliability
- **No network:** Fully offline, no accounts, no telemetry

### 4.2 Git Operations

| Operation | Command |
|---|---|
| List worktrees | `git worktree list --porcelain` |
| Diff (working vs HEAD) | `git diff HEAD` per worktree |
| File status | `git status --porcelain` per worktree |
| Branch info | `git branch --show-current` |

All git commands run with the worktree path set via `-C <path>` or `--work-tree`.

### 4.3 Performance

- Handle repos with up to 100 changed files without lag
- Diff parsing should be async and non-blocking on the main thread
- Large files (>5000 lines) should be truncated or lazily loaded

### 4.4 Data Model (in-memory only)

```
Repository
  - path: String
  - worktrees: [Worktree]

Worktree
  - path: String
  - branch: String
  - changedFiles: [DiffFile]

DiffFile
  - path: String (relative to repo root)
  - status: added | modified | deleted
  - hunks: [DiffHunk]

DiffHunk
  - oldStart: Int
  - newStart: Int
  - lines: [DiffLine]

DiffLine
  - type: context | added | removed
  - content: String
  - oldLineNumber: Int?
  - newLineNumber: Int?
  - comment: String?
```

---

## 5. Out of Scope (v1)

- Syntax highlighting
- Persistent comment storage
- Multi-repo support (one repo at a time)
- Staging/committing from the app
- GitHub/GitLab integration
- Diff between arbitrary commits/branches
- Comment categorization or labels
- Team/sharing features
- Customizable prompt templates

---

## 6. Future Considerations (v2+)

- Syntax highlighting per language
- Persistent comments with option to resume sessions
- Customizable prompt templates
- Diff against any branch/commit (not just HEAD)
- Direct integration with AI agents (paste prompt into API)
- Multiple repo support
