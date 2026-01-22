# CodexSessions

CodexSessions is a macOS/iOS app that indexes Codex CLI session logs (JSONL) and presents them as searchable conversations. It is optimized for very large, append‑only log files and incremental scanning.

## Features
- Incremental JSONL parsing (only reads new bytes).
- Tail‑only scanning for very large files (configurable).
- Skips giant single‑line payloads to avoid CPU/memory spikes.
- Local SwiftData store with optional CloudKit sync.
- Console status logging for scan progress.

## How It Works
- Session logs are discovered under `~/.codex/sessions` by default.
- Each `.jsonl` file is parsed line‑by‑line and cached.
- On subsequent scans, only newly appended data is read.
- For very large files, the scanner can parse only the last N MB (tail mode).

## Build & Run
Requirements:
- macOS 14+ (for the macOS app), iOS 17+ (for the iOS app)
- Xcode + command line tools
- Tuist

Common commands:
```
make generate
make build
make run
```
Or open the workspace directly:
```
make open
```

## Configuration
All config is via environment variables.

### Scanning / performance
- `CODEX_SCAN_BUDGET_MB` / `CODEX_SCAN_BUDGET_BYTES`:
  - Per‑rescan byte budget (default: 16 MB). Set to `0` for unlimited.
- `CODEX_TAIL_THRESHOLD_MB`:
  - Files larger than this use tail‑scan (default: 256 MB).
- `CODEX_TAIL_BYTES_MB`:
  - Tail size to parse when in tail mode (default: 8 MB).
- `CODEX_HEAD_BYTES_MB`:
  - Head scan size for metadata when in tail mode (default: 0.25 MB).
- `CODEX_MAX_LINE_MB` / `CODEX_MAX_LINE_BYTES`:
  - Max JSONL line size to parse; larger lines are skipped (default: 2 MB).

### Logging / diagnostics
- `CODEX_STATUS_LOG=0`:
  - Disable status logging (enabled by default).
- `CODEX_DEBUG_LOG=1`:
  - Enable verbose debug logs.
- `CODEX_DEBUG_UI=1`:
  - Show extra UI debug information in session list.
- `CODEX_ENABLE_POLLING=1`:
  - Force polling even when directory monitoring is active.

### CloudKit / signing
- `CODEX_DISABLE_CLOUDKIT=1`:
  - Force local‑only storage.
- `CODEX_CLOUDKIT_CONTAINER=...`:
  - Override the CloudKit container identifier.
- `CODE_SIGN_TEAM_ID=...`:
  - Set your Apple development team for signing.

### Codex CLI integration
- `CODEX_CLI_PATH=...`:
  - Override the Codex CLI binary path.
- `CODEX_NODE_PATH=...`:
  - Override the Node.js path used by the CLI wrapper.

## Data & Privacy
- The app reads session logs from your local filesystem.
- Parsed cache is stored under `~/Library/Application Support/CodexSessions/Parsed`.
- The SwiftData store is stored under `~/Library/Application Support/CodexSessions/`.
- No logs or user data are included in this repository.

## Open‑Source Hygiene
Before publishing, you may want to customize these identifiers:
- `Project.swift` bundle IDs and team ID
- `Resources/Info.plist` bundle identifier
- `Entitlements/CodexSessions.entitlements` CloudKit container
- `Sources/Shared/Services/ModelContainerFactory.swift` default container

## License
Add your preferred license here.
