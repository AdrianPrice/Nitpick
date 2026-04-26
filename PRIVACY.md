# Privacy Policy

**Last updated:** April 26, 2026

## Overview

Nitpick is designed with privacy as a core principle. The app operates entirely on your local machine and does not collect, transmit, or store any personal data externally.

## Data Collection

Nitpick collects **no data**. Specifically:

- **No analytics or telemetry** — the app does not track usage, crashes, or behavior
- **No network requests** — the app makes no outbound connections of any kind
- **No accounts or authentication** — there is no sign-up, login, or user identity
- **No third-party SDKs** — no advertising, analytics, or tracking frameworks are included

## Data Stored Locally

Nitpick stores the following data on your Mac, solely to provide app functionality:

- **Comments** — your code review comments are saved as JSON files in `~/Library/Application Support/Nitpick/` so they persist across app launches
- **Preferences** — your prompt preamble and last opened repository are stored in standard macOS user defaults
- **Security-scoped bookmarks** — used to remember repository access permissions under App Sandbox

All locally stored data remains on your device and is never transmitted anywhere.

## Repository Access

Nitpick reads your git repositories using libgit2 to display diffs and file status. It does not modify your repositories — no commits, pushes, or file changes are made by the app.

## Your Rights

Since no personal data is collected, there is nothing to request, export, or delete. You can remove all locally stored app data by deleting:

- `~/Library/Application Support/Nitpick/`
- Nitpick preferences via `defaults delete com.adrianprice.Nitpick`

## Contact

If you have questions about this privacy policy, please [open an issue](https://github.com/AdrianPrice/Nitpick/issues/new).
