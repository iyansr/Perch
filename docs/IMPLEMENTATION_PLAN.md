# Perch v0.1 — Implementation Plan

Source: [PRD.md](PRD.md) v0.1 · Visual reference: [prototype.html](prototype.html) · Plan date: Oct 29, 2026

## 0. Current state

Commit `60fc978` (scaffold) builds clean (`xcodebuild -scheme Perch`, Debug). Most of Day 1 is already in place.

| PRD item | Status | Where |
| --- | --- | --- |
| NotchPanel (non-activating, key-capable, all Spaces) | Done | `Notch/NotchPanel.swift` |
| ScreenManager (notch vs island, live on display change) | Done | `Notch/ScreenManager.swift` |
| Three states idle / glance / open + morph animations | Done | `Notch/NotchModel.swift`, `NotchController.swift`, `Views/NotchMotion.swift` |
| Global hotkey | Partial: fixed ⌥Space, no user choice | `Hotkey/HotkeyManager.swift` |
| App search, ↑↓ ↵ esc, click-outside close, recents | Done | `Search/AppIndex.swift`, `SearchEngine.swift` |
| Inline math + units, web fallback | Done | `Search/Calculator.swift`, `UnitConverter.swift` |
| System Settings panes in search (`wallpaper`, `dock`, `dark mode`) | Code + unit tests done: panes matched by title and aliases, shown with their own Settings icons, opened via `x-apple.systempreferences:` URLs; listed above apps when the pane match is stronger; panes missing on the running macOS are hidden. Manual check that each pane lands on the right page pending | `Search/SystemSettingsPane.swift`, `SearchEngine.swift` |
| Search modes (chips replaced, decision 12) | Done: one sectioned root list; Commands open Clipboard History and Search Files | `SearchMode`, `PerchCommand` in `SearchEngine.swift`, `Search/FileSearch.swift` |
| ActivityCenter + timer (`t 25m`), pause/resume, 8 s auto-dismiss, sound toggle | Done | `Activities/*` |
| F2 Clipboard, F4 Drop-to-convert | Code + unit tests done; manual exit checks (J3, J4, Finder drag) pending | `Clipboard/*`, `Convert/*`, `Notch/DropZoneController.swift` |
| F6 Agents: `perch` CLI, socket bridge, hook installer, terminal focus | Code + unit tests done; verified with a real `claude -p` session through Perch hooks; J6 tab focus and "connect on this machine" pending | `PerchCLI/`, `Shared/AgentEvent.swift`, `Agents/*` |
| F5 Ask AI | Dropped from v0.1 (decision 11); the AI chip is removed too | — |
| J1 Onboarding, hotkey recorder, settings | Done; step 3 (agents) added; Settings is its own window (decision 13) | `Onboarding/*`, `Settings/*`, `Hotkey/*`, `App/AppSettings.swift` |
| Unit test target | Done (`PerchTests`, 99 tests) | `PerchTests/` |
| Signing, notarization, Sparkle, DMG | Not started | — |

Project facts: macOS 14 target, no sandbox, hardened runtime on, `LSUIElement = YES`, default actor isolation `MainActor`, file-system-synchronized groups (new files under `Perch/` join the target automatically). Targets: `Perch` (app), `PerchCLI` (product `perch`, module `PerchCLI` so it does not clash with `Perch` on a case-insensitive disk), `PerchTests`. `Shared/` is compiled into both the app and the CLI. SPM: GRDB, libwebp. `Perch.entitlements` carries `com.apple.security.automation.apple-events`.

## 1. Decisions and PRD deviations

Facts below came from inspecting this machine (Claude Code 2.1.312, codex-cli 0.164.0). Each item needs sign-off only if marked **Decide**.

1. **WebP output needs a library.** `CGImageDestinationCopyTypeIdentifiers()` on macOS returns jpeg, png, jpeg-2000, heic, heics — no WebP. `sips` uses the same ImageIO encoders. Plan: add SPM `SDWebImage/libwebp-Xcode` and encode WebP through it; all other formats stay on ImageIO.
2. **Codex supports hooks now.** `~/.codex/hooks.json` uses the same schema as Claude Code hooks, including the PascalCase event names (`SessionStart`, `PermissionRequest`, `Stop`, …; checked against captured payloads). The `notify` program in `config.toml` only fires on turn completion. Plan: connect Codex through `hooks.json`, so "needs input" works for both agents. The `notify` path is dropped. Codex runs a new hook only after the user approves it in Codex; it records approval in `config.toml` as `[hooks.state."<hooks.json>:<event>:<group>:<hook>"]`. Perch never writes those entries, appends its group after existing ones (so other tools' indexes do not shift), and shows "Open Codex and approve Perch's hooks" until the entries appear.
3. **Claude Code "needs input" uses `PermissionRequest`.** Claude Code has a dedicated `PermissionRequest` hook, plus `Notification` for idle prompts. Plan: subscribe to `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `Notification`, `PostToolUse` (clears needs-input after approval), `Stop`, `StopFailure`, `SessionEnd`.
4. **Decide — CLI name.** The PRD says `notch event` / `notch watch`. Plan uses `perch` to match the app and avoid collisions with other notch apps.
5. ~~**Decide — ⌘-digit chip order.**~~ Superseded by decision 12: there are no chips or ⌘-digit shortcuts.
6. **Clipboard storage:** GRDB via SPM, as in the PRD. Image payloads are stored as files under Application Support, not as blobs, to keep the DB small and queries fast.
7. **Hotkey:** keep the Carbon `HotkeyManager` and add a small in-app recorder. The KeyboardShortcuts package is not needed.
8. **Hooks are guarded.** Every hook command written to an agent config is a no-op when Perch is not installed. This matches how other tools on this machine write hooks (`[ -x … ] && … || true`). Uninstalling Perch never breaks an agent.
9. **`SessionStart` only tracks the session.** A freshly opened agent waiting for its first prompt is not "running", so `SessionStart` shows nothing; the first `UserPromptSubmit` creates the row.
10. **Codex `Interrupt` ends a turn.** Codex has no `Notification` / `StopFailure`; its `Interrupt` event (the user cancelled a turn) maps to done, so the row does not spin until the 30 min timeout.
11. **Ask AI (F5) is dropped from v0.1.** Removed with it: the AI chip, the `.ask` result, Tab-to-ask, the onboarding/settings key step, Keychain storage and the `aiProvider` setting. The demo and acceptance matrix skip J5 / F5-a.
12. **Chips are replaced by one list and commands (Tinycast/Raycast layout).** The root search shows one list grouped under section headers (Results, Applications, Commands, Web) with a right-aligned kind label and a footer action bar (`↵` primary action, `⌘↵` Reveal in Finder for files, esc). Built-in commands — Clipboard History, Search Files, Settings, Quit Perch — are matched like apps (title plus aliases, no loose subsequence hits). Clipboard History and Search Files push a mode, shown as a tag in front of the search field; esc or ⌫ on an empty query returns to the root list. The Home Clipboard module opens Clipboard History directly, so esc there returns Home. `clip ` still jumps to Clipboard History. The list shows as soon as search opens: with an empty query it lists Recent (recently launched apps), Applications (every other app, A–Z), then Commands.
13. **Settings is a window, not the onboarding card (Tinycast layout).** A titled window with a sidebar (General, Clipboard, Agents, Permissions, About) and grouped rows: hotkey recorder and sounds; clipboard history toggle and Clear History; agent connect rows with the hook diff; Accessibility status, prompt and System Settings link; app version. It opens from a gear at the bottom left of Home, the pill menu's "Settings…" and the Settings command; each collapses the surface first. The onboarding card is first-run only.

## 2. Architecture additions

```
Perch/
  App/            PerchApp.swift, AppSettings.swift (UserDefaults-backed @Observable)
  Notch/          (existing) + DropZoneController.swift
  Hotkey/         HotkeyManager.swift, Shortcut.swift, ShortcutRecorderView.swift
  Search/         (existing) + FileSearch.swift (NSMetadataQuery)
  Clipboard/      ClipboardMonitor.swift, ClipboardStore.swift, ClipboardItem.swift, Paster.swift
  Convert/        ImageConverter.swift, ConversionAction.swift, ConversionJob.swift
  (AI/ — dropped with Ask AI, decision 11)
  Agents/         AgentBridge.swift (socket server), AgentSessions.swift, AgentConnections.swift (connect state),
                  HookInstaller.swift, OrderedJSON.swift (key-order-preserving JSON), UnifiedDiff.swift,
                  TerminalFocuser.swift
  Onboarding/     OnboardingView.swift, OnboardingState.swift, AgentStepViews.swift
  Settings/       SettingsWindowController.swift, SettingsView.swift (sidebar + row building blocks), SettingsPages.swift
Shared/           AgentEvent.swift (wire format), compiled into the app and the CLI
PerchCLI/         main.swift (`perch event`, `perch watch`)
PerchTests/       unit tests; Fixtures/ holds hook payloads captured from Claude Code 2.1.312 and codex-cli 0.164.0
```

### Shared contracts

**`SearchMode`** is `root, clipboard, files`. `root` lists apps, `PerchCommand`s, answers and the web fallback; the commands push the other two modes. (Chips and ⌘1–⌘4 existed until decision 12; an `ai` chip existed until Ask AI was dropped.)

**`SearchResult`** gains:
- `.clip(ClipboardItem)`: ↵ pastes, ⌘↵ copies.
- `.file(URL)`: ↵ opens, ⌘↵ reveals in Finder.

**`Activity.Kind`** grows to `.timer`, `.conversion(batchID)` and `.agent(source: AgentSource, sessionID: String)`. Glance actions per kind:

| Kind | Glance actions |
| --- | --- |
| Timer | Pause/resume (done) |
| Conversion | Reveal in Finder |
| Agent | Focus terminal |

Add `ActivityCenter.upsert(id:…)`, so repeated agent events update one row and do not stack duplicates.

**Agent wire format** is one JSON object per line over the socket at `~/Library/Application Support/Perch/perch.sock`:

```json
{"v":1,"source":"claude","type":"permission_request","session":"<id>","cwd":"/path/api-server",
 "message":"Allow Bash: npm test?","term":{"program":"Apple_Terminal","tty":"/dev/ttys004","pid":1234},"ts":1730000000}
```

`AgentEvent` is a single file compiled into both the app and the CLI targets. `v` gates format changes.

**State mapping** from hook events to `Activity.Status`:

| Hook event | Status |
| --- | --- |
| `UserPromptSubmit`, `PostToolUse` | running |
| `SessionStart` | tracked, no row (decision 9) |
| `PermissionRequest`, `Notification` | needsAttention |
| `Stop`, `Interrupt` (Codex) | done |
| `StopFailure` | failed |
| `SessionEnd` | dismiss |

Both agents send PascalCase names; the CLI normalises them to snake_case on the wire. `perch watch` sends `start` (running) and `exit` (done on code 0, failed otherwise).

## 3. Work plan

Order follows the PRD's 3-day schedule. Each task lists its exit check. The `PerchTests` target is created in task 1.1, and later tasks add tests only for real logic. Wiring is not tested.

### Day 1 remainder — first launch, hotkey, chips

**1.1 Test target + settings model**
- Add the `PerchTests` unit-test target (hosted by Perch).
- Port boundary tests for `TimerCommand.parse`, `Calculator.evaluate`, `UnitConverter.convert` (`24*7`, `5 km to mi`, `t 1h30m`, `t 0`, `t 25h`).
- Add `AppSettings` with the following keys: `hotkey`, `onboardingDone`, `playsSounds` (move from `ActivityCenter`), `clipboardEnabled`. (`aiProvider` was removed with Ask AI.)
- Exit: `xcodebuild test` green.

**1.2 Configurable hotkey**
- `Shortcut { keyCode, carbonModifiers }` is Codable and persisted.
- `ShortcutRecorderView` captures the next keyDown through a local monitor and requires at least one modifier.
- `HotkeyManager.register(shortcut)` returns false on conflict, and the recorder shows "Taken by another app".
- `NotchController` re-registers when the setting changes.
- Exit: record ⌃⌥P → it toggles the panel; ⌥Space no longer does.

**1.3 Onboarding (J1)**
- First launch shows a "hello" pulse (reuse the `completionTick` keyframe), then the card drops from the notch in a new `NotchState.onboarding` that is sized like `.open`.
- The card has three steps:
  1. Hotkey recorder, prefilled ⌥Space.
  2. Accessibility, via `AXIsProcessTrustedWithOptions` with prompt. "Skip" keeps copy-only mode, and the status is polled every 1 s while the step shows.
  3. Connect Claude Code / Codex, using the buttons from task 3.2. A diff sheet appears before any write.
- ~~Optional: an API key field (task 3.4).~~ Dropped with Ask AI.
- On finish, the card collapses into the notch with "Press ⌥Space anytime" for 2 s.
- Settings: see decision 13 (gear in Home, pill menu "Settings…", Settings command).
- Exit: delete defaults → relaunch → full J1 flow on both notch and island.

**1.4 Chips: Clipboard, Files (AI removed, decision 11)**
- Add the scopes and their chip UI.
- Files: `FileSearch` wraps `NSMetadataQuery` (`kMDItemFSName LIKE[cd] "*q*"`, home + /Applications scope, 30 results, debounced at 120 ms).
- ~~AI: shows the `.ask` row only.~~ Removed with Ask AI.
- Typing `clip ` in All switches to Clipboard and strips the prefix.
- Exit: ⌘1–⌘4 switch chips; files open on ↵.

### Day 2 — Clipboard history (F2) and Drop-to-convert (F4)

**Reference.** Clipboard behaviour, shortcuts and visual tokens follow [tinycast](https://github.com/abue-ammar/tinycast) (Features/Clipboard, DesignSystem). It is AGPL-3.0: use it as a reference for UI and behaviour only. NEVER copy or adapt its source into Perch. All code is written independently. Do not reuse its geometry: its panel is 750 × 475 with a 290 pt list, and Perch's clipboard panel uses the search-mode width `NotchGeometry.searchPanelWidth` = 520 (250 pt list, 340 pt split) inside a 760 pt `windowSize`. Reuse only token values: spacing 2/4/6/8/10/12, radii (row 10, thumbnail 6, bar control 8, keycap 6), keycap chip 18 pt, and the opacity ramps (selection 10 %, hover 5 %, control surface 10 %, border 20 %, secondary text 60 %).

**2.1 ClipboardStore**
- Add GRDB. Table `clip(id, kind[text|image|file], text, imagePath, sourceBundleID, hash UNIQUE, pinnedAt NULL, createdAt)`.
  - A `file` row stores the absolute path(s) in `text` and never copies the file. `imagePath` stays nil, so retention and delete never touch a user file.
  - A link, email or colour is derived from `text` on demand, never stored (`ClipboardItem.textForm`).
- Dedupe by content hash: re-copying the same content updates the existing row's `createdAt` in place (no delete + insert).
- Pins: `pin(id)` / `unpin(id)`. Unpinning makes the row the newest entry. Pinned rows order first, oldest pin first, and pasting a pinned row does not promote it.
- Retention: delete unpinned rows beyond 200, or older than 7 days, on every insert and at launch. Delete orphan image files at the same time. Never delete files outside the image directory.
- Search: `LIKE` on text and file names, newest first, limit 50. Pinned rows still lead. Optional type filter: all, text, links, emails, colors, images, files, applied after the pinned split.
- `clearHistory()` deletes unpinned rows and their image files. It must work even when `clipboardEnabled` is false.
- A database that cannot be opened is deleted and recreated.
- Tests: retention boundaries (201st item, 7 days + 1 s), dedupe update in place, pin ordering and retention skip, unpin → newest, clear keeps pins.
- Exit: tests green.

**2.2 ClipboardMonitor**
- Poll `NSPasteboard.general.changeCount` every 0.5 s on a `Timer`. Read the pasteboard only when the count changes. `AppSettings.clipboardEnabled == false` stops the timer.
- Skip an item when its types include `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`, or `com.agilebits.onepassword`. These guards come first and are unconditional.
- Skip Perch's own writes: every `Paster` write stamps a private pasteboard type (`com.perch.internal`), and the poller skips any item carrying it. The poller still relies on `changeCount` to notice changes.
- Read file URLs before text. Finder puts the file's display name on the plain-string type, so a text-first read would store `IMG_1234.png` as prose.
  - Reject files under `/tmp`, `/var/folders` and `~/Library/Caches`. Finder hands over `/private/tmp/…` and `/private/var/folders/…`, so compare `url.resolvingSymlinksInPath().path` against the resolved roots, never a raw `hasPrefix("/tmp")`. If every file is rejected, fall through to the text branch.
  - Cap one batch at 32 files.
  - Read each item's own `public.file-url`, so a copied `http` URL stays a link.
- Text is capped at 32,000 characters. Images are re-encoded to PNG off the main actor, and capture is skipped if the image exceeds 20 MB.
- Tests: the volatile-root reject matches `/private/tmp/x`, `/tmp/x` (symlink) and `/private/var/folders/x`, and accepts `~/Documents/x`; the 32-file cap; a file URL wins over the display-name string.
- Record the frontmost app as the source.
- Exit: copy in Safari → row in < 1 s; copy a password in 1Password/Passwords.app → no row; copy a file in Finder → file row, not a text row with its name.

**2.3 Paste and Clipboard UI**
- Layout: Raycast-style split. Two widths: home, onboarding and drop zone use the default `NotchGeometry.panelWidth` = 480; search mode (search row + results, including clipboard) uses `NotchGeometry.searchPanelWidth` = 520, and the surface morphs out from home to it. Both fit in the 760 pt `windowSize`. Left: 250 pt list, each row a text preview, image thumbnail, file icon or colour swatch; pinned rows under a "Pinned" header. Right: preview of the selected clip (monospaced text, fitted image, file list, colour swatch) over an "Information" table (source app, type, characters/words, dimensions/size, copied time). Click selects, double-click pastes. Selection lands on the newest unpinned row after any reset.
- Thumbnails: decode a 256 px derivative for rows and a 900 px one for the selected-row preview, cached in memory. Never decode the full bitmap per row.
- Footer: "Clear history" (with a confirm step) and the type filter on the left; `⌘↵ Copy`, `⌘. Pin` hints and a primary "Paste to <App> ↵" button on the right, naming the app that had focus when the panel opened.
- Type filter: a fixed-width popover (about 200 pt) on ⌘P, opened on the active filter. A filter that empties the list shows "No <type> in history", not "history is empty". ⌘P does not clash with the ⌘1–⌘4 chips.
- Chords:

  | Chord | Action |
  | --- | --- |
  | ↵ | Paste |
  | ⌘↵ | Copy only |
  | ⌃⌘↵ | Paste as plain text (text rows; a file row pastes its path; an image falls back to ⌘↵) |
  | ⌥↵ | Paste and keep the panel open; does not promote |
  | ⌘. | Pin / unpin |

- `Paster.paste(item)`:
  1. Write the item to the pasteboard, with the private marker. A text row writes `.string`. A file row writes `public.file-url` plus the path as `.string`. An image writes PNG data. If a file or image no longer exists on disk, write nothing, show a HUD, and keep the row.
  2. Close the panel and restore focus to `previousApp` (existing `returnKeyboardFocus`). ⌥↵ keeps the panel open and posts to the target pid instead of activating it.
  3. After the app becomes active (observe `didActivateApplicationNotification`, 300 ms timeout), post ⌘V via `CGEvent` to `.cghidEventTap`. Drop a second paste within 0.25 s of the last one.
  4. After the paste is posted, call `store.promote(id)` (update `createdAt` in place) for unpinned rows. Skip it for pinned rows and for ⌥↵, including when ⌥↵ falls back to copy. The marker makes the poller ignore Perch's own write, so promotion must be explicit or a re-pasted old clip stays buried. ⌘↵ and the no-Accessibility fallback of ↵ and ⌃⌘↵ also promote.
- Accessibility is required for the synthetic ⌘V and onboarding lets the user skip it. Without it, ↵, ⌃⌘↵ and ⌥↵ fall back to copy only and show "Copied — enable paste in Settings" in the pill for 2 s.
- Exit: J3 end-to-end in TextEdit and Slack, and the copy fallback with Accessibility revoked.

**2.4 Drop zone**
- Detect a drag start globally: in the existing global `.leftMouseDragged` monitor, compare `NSPasteboard(name: .drag).changeCount` to the last seen value.
- On a new drag that carries file URLs:
  - Set `panel.ignoresMouseEvents = false`.
  - Grow the interactive rect to a `panelWidth` × 120 pt band along the top edge (the PRD drag-target risk).
  - Enter a new `NotchState.dropZone` labelled "Drop to convert".
- `NotchPanel` registers for `.fileURL` and implements `NSDraggingDestination` on its content view: highlight on enter, revert on exit or on `.leftMouseUp` with no drop.
- Non-image files show "Images only in v0.1" and reject the drop.
- On drop, open the panel with the action list for the files.
- Exit: drag from Finder toward the top on notch and island → zone appears; releasing elsewhere restores idle.

**2.5 ImageConverter**
- Actions: PNG, JPG (q 0.85), WebP (q 0.8, libwebp), HEIC (q 0.8), Resize 50 %, Compress (same format, JPEG/HEIC q 0.6, PNG → lossy WebP not allowed, so PNG is re-encoded with metadata stripped).
- Pipeline: `CGImageSourceCreateWithURL` → `CGImageSourceCreateThumbnailAtIndex` for resize, applying the orientation transform → `CGImageDestination`. Encoding runs on a detached task, max 4 concurrent.
- Output goes next to the original as `name-<suffix>.<ext>`:
  - Suffixes: `-compressed` for Compress, `-50` for Resize, none for a format change unless the name collides.
  - A collision adds ` 2`, ` 3`, and so on.
  - The original is opened read-only and never written.
- If the folder is not writable, save to `~/Downloads` and say so in the activity detail.
- A batch is one `Activity`, `.fraction(done/total)`. When the batch ends, Finder reveals all outputs (`activateFileViewerSelecting`).
- Tests:
  - Suffix and collision naming.
  - HEIC → JPG fixture output is a valid JPEG with the same pixel size.
  - The original file's hash is unchanged after conversion.
- Exit: 4 MB HEIC → JPG in < 2 s on Apple Silicon (log the timing); J4 end-to-end.

### Day 3 — Agents (F6), demo

**3.1 AgentBridge + `perch` CLI**
- New command-line tool target `PerchCLI`, product `perch`, copied into `Perch.app/Contents/Helpers/` by a Copy Files phase.
- `perch event --source claude|codex`:
  1. Reads the hook JSON from stdin.
  2. Picks `session_id`, `cwd`, `hook_event_name`, `message`/`tool_name`.
  3. Adds `TERM_PROGRAM`, `__CFBundleIdentifier` (the launching terminal app), the tty (`ttyname(STDIN)`, else the nearest ancestor's controlling tty read with `sysctl(KERN_PROC_PID)`, no `ps` subprocess), and the user's shell pid (the first shell above the agent process). Tool output and file contents are dropped: the line carries only a ≤160-character summary.
  4. Writes one line to the socket with a 200 ms connect timeout.
  5. Always exits 0 and prints nothing, so the agent is never blocked or altered.
- `perch watch -- <cmd>` runs the command with inherited stdio, sends `start`, then `exit` with the code and duration, and forwards the child's exit code (`128 + signal` when killed, 127 when it cannot start).
- `PERCH_SOCKET` overrides the socket path; tests use it to run the real helper against a temporary socket.
- `AgentBridge`:
  - A `DispatchSource`-driven Unix socket server. The socket file uses mode 0600, and any stale socket is removed at launch.
  - Decoded events are passed to `AgentSessions`, which maps them to `ActivityCenter.upsert` using the table in §2.
  - Title is "Claude · <cwd basename>"; detail is the last event text.
  - A session that sends nothing for 30 min is dropped.
- Tests: decoding of real hook payload samples saved as fixtures from this machine, and the event → status mapping.
- Exit: `echo '{…}' | perch event --source claude` shows a pill activity in < 1 s.

**3.2 HookInstaller**
- Targets: `~/.claude/settings.json` and `~/.codex/hooks.json`.
- Merge rules:
  - Parse the JSON and append one entry per event, keeping every existing hook.
  - Each entry is marked by a command containing `Perch.app/Contents/Helpers/perch`, so re-running is idempotent and "Disconnect" removes only Perch entries.
  - The command is guarded:
    ```sh
    P='/Applications/Perch.app/Contents/Helpers/perch'; [ -x "$P" ] && "$P" event --source claude || true
    ```
    The path is resolved from `Bundle.main` at install time.
- Before writing:
  1. Show a unified diff (old vs new JSON) inline in the card, with Connect / Cancel. The file is edited key-order-preserving, so the diff shows only Perch's lines and an untouched file round-trips byte for byte (checked on this machine's real configs).
  2. Back up to `<file>.perch-backup-<timestamp>`.
  3. Write atomically.
- Version check at launch: run `claude --version` / `codex --version`, found on PATH via a login shell `zsh -lc`, with a 2 s timeout. Store the result, and show "Untested version" in Settings if it is newer than the tested major version.
- Tests:
  - Merging into fixtures with existing third-party hooks keeps them byte-for-byte equivalent after a JSON round-trip.
  - The second install is a no-op.
  - Uninstall restores the same JSON.
- Exit: connect both agents on this machine; existing Orca/Superset/cux hooks still present.

**3.3 TerminalFocuser**
- Map `TERM_PROGRAM` to a bundle ID: Apple_Terminal, iTerm.app, WezTerm, ghostty, vscode / cursor, warp.
- Activate that app with `NSRunningApplication`.
- For Terminal and iTerm, also select the tab whose tty matches, via AppleScript. This needs the Automation permission, requested on first use. If it is declined, activating the app is enough.
- Exit: J6 click focuses the right Terminal tab.

**3.4 Ask AI — deferred, not in v0.1 (decision 11).** It was built and then removed. The spec below is kept for a later version.
- `Keychain` holds a generic password per provider (`com.perch.ai.anthropic` / `.openai`).
- `AIClient.stream(prompt, context)` uses `URLSession.bytes(for:)` and an `SSEParser`:
  - Anthropic: `POST /v1/messages`, `stream: true`; reads `content_block_delta.text`.
  - OpenAI: `POST /v1/chat/completions`, `stream: true`; reads `choices[0].delta.content`.
  - The model ID is a constant per provider (`claude-sonnet-5-5`, `gpt-6.1-terra` with `reasoning_effort: none`) and can be changed in Settings.
- Tab in the search field (only when the query is non-empty) switches to the AI chip and starts the stream.
- `AnswerView` renders Markdown blocks: paragraphs, fenced code with a monospaced background, lists, and inline styles through `AttributedString(markdown:)`. The panel grows up to `windowSize` and scrolls after that.
- ⌘C copies the raw Markdown. esc cancels the task and closes.
- A "Use clipboard" toggle prepends the latest clipboard text, capped at 8 KB.
- With no key, the AI chip shows an inline key field, provider picker, and Save, instead of an error.
- Network failures show an inline retry row.
- Tests: `SSEParser` handles split chunks, multi-line `data:`, `[DONE]`, and the Anthropic `event:` lines.
- Exit: first token < 1.5 s (log the timing); J5 end-to-end.

**3.5 Demo + polish**
- Run the full acceptance pass (§4) on the notch and in clamshell.
- Fix motion and timing issues found.
- Record a 15–30 s demo with three moments: J2 search → J4 drop-to-convert → J6 agent needs input → done.

### Release (after the 3 days, before launch)

**R.1 Sparkle**
- Add Sparkle via SPM: `SPUStandardUpdaterController`, a "Check for Updates…" menu item, an EdDSA key, and an appcast hosted on GitHub Releases.

**R.2 Signing and DMG**
- Sign with Developer ID: app and embedded `perch` CLI, hardened runtime.
- Entitlements: `com.apple.security.automation.apple-events`. Add `NSAppleEventsUsageDescription` to the Info.plist.
- Build the DMG with `create-dmg`, then run `xcrun notarytool submit --wait` and `stapler staple`.
- Put this in `scripts/release.sh`.

**R.3 Release settings**
- Add the Settings toggle "Launch at login" (`SMAppService.mainApp`). This is the only Settings addition, and it is needed for an ambient app.

## 4. Acceptance matrix

Run on a notched MacBook and in clamshell with an external display. Every row maps to a PRD acceptance line.

| ID | Check | How measured |
| --- | --- | --- |
| F1-a | Panel visible < 100 ms after hotkey | `os_signpost` from hotkey callback to first frame of `.open`; Instruments |
| F1-b | First keystroke lands in the field | Press hotkey and type `fig` immediately; field shows `fig` |
| F1-c | Frontmost app keeps its menu bar | Open over Safari; menu bar still reads Safari |
| F2-a | Safari copy visible < 1 s | Poll interval 0.5 s + DB write; manual timing |
| F2-b | Password never stored | 1Password and Passwords.app copy → `SELECT count(*)` unchanged |
| F3-a | 25 min timer survives panel close/reopen | Start, open/close panel 5×, countdown continuous |
| F3-b | Finish animation + sound, sound toggle works | `t 5s` with toggle on/off |
| F4-a | 4 MB HEIC → JPG < 2 s, original untouched | Logged duration; SHA-256 before/after |
| F5-a | Deferred with Ask AI | — |
| F6-a | Claude permission prompt → amber < 1 s | Real session: ask Claude to run a shell command |
| J7 | Lid close/open switches modes without restart | Close lid with external display, then reopen |
| Spaces | Panel shows over a full-screen app | Safari full screen, press hotkey |

## 5. Risks specific to this plan

| Risk | Mitigation |
| --- | --- |
| Synthetic ⌘V lands before the target app is key | Wait for `didActivateApplicationNotification`; 300 ms cap; verified in 2.3 against TextEdit/Slack/Terminal |
| Drop target needs `ignoresMouseEvents = false` during drags, which can swallow clicks | Enabled only between drag-start and mouse-up; reset on any `.leftMouseUp` |
| Hook command slows agents | CLI exits 0 always, 200 ms socket timeout, no stdout |
| Hook JSON fields change between agent versions | CLI forwards unknown fields raw; app decodes leniently; `perch watch` fallback; version check (3.2) |
| libwebp adds build time / binary size | Only the encoder module linked; acceptable for v0.1 |
| AppleScript tab focus prompts for Automation | Requested on first click only; app-level activate as fallback |

## 6. Out of scope (unchanged from PRD)

These stay out of v0.1:

- Plugins
- Media, calendar, AirDrop
- Video/audio conversion
- Multi-monitor islands (main screen only)
- Localisation
- Battery in the island
- Ask AI (F5), deferred (decision 11)
- Settings beyond hotkey, agent connect, sounds, and launch at login
