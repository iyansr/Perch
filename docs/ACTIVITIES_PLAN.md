# Perch — Live Activities Expansion Plan

Source: [PRD.md](PRD.md) F3/F6 · Builds on [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) · Plan date: Oct 30, 2026

Goal: every activity a competing notch app shows should be available in Perch's shared live-activity slot, behind a per-source toggle, without turning Perch into a second Control Center. v0.1 ships three sources (timer, conversion, agent). This plan adds the rest in four releases.

## Status

§1 and Releases A, B and C are implemented (Oct 30, 2026); C is code-complete but entirely unverified on hardware. Where the build differs from the text below:

- **Kinds.** `Activity.Kind` has the A, B and C cases. `download` is keyed by the partial file's path rather than a URL. `Kind.owner` names the source whose handlers `ActionRouter` (card buttons, reply text) and `DecisionRouter` (two-button questions, keyed by `PendingDecision.owner`) call. Generic card fields: `actions`, `replyPlaceholder`, `image`, `badgeImage`, `link`, `decision`.
- **Progress.** `.waveform` carries `playing: Bool`, so a paused track shows resting bars.
- **Sources.** `ActivitySource` exposes `static info` (Settings title, symbol, permission kind); `permission` is derived from it. `SourcePermission` carries the kind in `.granted` / `.denied` too, so the Settings row can link the right pane.
- **A1.** The adapter is vendored in `Vendor/mediaremote-adapter` and built by `Scripts/build-mediaremote-adapter.sh` (clang, no CMake) into `Contents/Resources/MediaRemoteAdapter/`. The stream runs with `--allow-missing-title`; untitled media (QuickTime, some web video) is named after its app. The AppleScript fallback starts when the adapter is missing or its stream exits. The music card's artwork is 56 pt, not 72 pt, so artwork, scrubber and transport fit in 150 pt.
- **A2.** Volume comes from a CoreAudio listener on the default output device instead of the key tap: it needs no permission and catches menu-bar and app changes too. Brightness, keyboard backlight and Caps Lock use NSEvent global + local monitors (Accessibility), including the 144/145 key codes Apple silicon keyboards send. A listen-only `CGEventTap` was dropped: macOS created it without any permission and then delivered nothing. "Replace system HUD" runs `launchctl kickstart -k` then `kill SIGSTOP` on `OSDUIHelper`, re-applies on wake, and resumes it on quit.
- **A3.** AirPods charge comes from IOBluetoothDevice's `batteryPercent*` properties. Magic accessories come from the `AppleDeviceManagementHIDEventService` entry (`BatteryPercent`), matched by address.
- **A4.** The Timer module's presets are 5 min, 25 min and Pomodoro (the 50 min chip made room). `t pomo` / `t pomodoro` starts one from search.
- **B1.** Ambient detail is the start time; T−10 min it turns persistent + `needsAttention` with a countdown, a Join button and "Open in Calendar". It stays joinable until 5 min after the start, and events more than 12 h out stay off the pill.
- **B2.** On by default (no permission). The chip shows the sensor only, as planned; the row has no dismiss button because the sensor, not the user, ends it.
- **B3.** Caps Lock shares the HUD source's key tap (`flagsChanged`, key code 57) and its Settings toggle.
- **B4.** Off by default: macOS asks once for Downloads-folder access. A partial file older than 2 min when first seen is ignored as a leftover, and one with no change for 5 min is dropped.
- **B5.** Wire protocol: `perch event --await` adds `"request": <uuid>` and waits; the app replies `{"allow":Bool,"request":id,"v":1}` and the CLI prints the hook JSON. The hook command is `… --await || true` with `timeout: 120`; old installs show "Update Perch's hooks…" (`AgentConnections.Status.needsUpdate`). Codex is enabled too: its bundled hook schema has the same `PermissionRequest` input and `decision.behavior` output, but no live `codex-PermissionRequest.json` was captured, and updating Codex's hook makes Codex ask to trust it again. The decision card (§3.7) stays open until answered or withdrawn; Esc/↵ shortcuts are not wired, because the hover card never takes keyboard focus.
- **C1.** Zoom detection reads Zoom's menu bar over AX (a menu holding Mute/Unmute audio exists only during a meeting) instead of mic-in-use + frontmost app, which also fires outside calls. Mute/camera press those menu items, with ⌘⇧A/⌘⇧V posted to Zoom as the fallback; Leave posts ⌘W and presses "Leave meeting", never "End meeting for all". Meet runs JavaScript in Chrome/Edge/Arc `meet.google.com` tabs only with "Google Meet controls" on; state comes from English aria-labels. Polls at 1 Hz only while Zoom (or a browser with Meet controls on) runs.
- **C2.** The reader tries both `~/Library/Group Containers/group.com.apple.usernoted/db2/db` and `$(getconf DARWIN_USER_DIR)/com.apple.notificationcenter/db2/db`, read-only (not `immutable=1`, which would miss the WAL), polling every 2 s from the newest `rec_id`. Schema and blob keys are assumed, not observed (no Full Disk Access in the dev shell); a mismatch disables the feed and logs once. Replies go through Messages AppleScript with the text passed as an argument; chat targeting falls back from chat GUID to identifier to participant name. The message stays while its reply field has focus.
- **C3.** Geocoding uses Open-Meteo's geocoding API instead of `CLGeocoder` (same provider, no key, testable); Location (When In Use) is only asked for when the City field is empty, so the source has no permission chip. Refresh every 30 min and on wake, exponential backoff on errors, readings older than 3 h are dropped. Fixtures are real Open-Meteo responses.
- **C4.** `SpeechAnalyzer` with `SpeechTranscriber` when the locale is supported, else `DictationTranscriber` (model downloaded on demand; neither supporting the locale fails with "Language not supported"). Text is inserted by pasting through `Paster` and the previous clipboard is restored about 0.6 s later; without Accessibility the text stays on the clipboard and the card says so. Default shortcut ⌃⌥D.
- **C5.** Parses the English sentence "<sender> would like to share <file>" (plus variants) from `com.apple.sharingd` records, falling back to title = sender, body = file. Accept/Decline press buttons titled Accept/Decline in `com.apple.notificationcenterui` windows: still an inference. Auto-accepted transfers (own Apple ID devices) post no question, so the source also watches `~/Downloads` for files whose `com.apple.quarantine` agent is `sharingd` (`0081;<hex time>;sharingd;<uuid>`, confirmed on 26 real AirDropped files); files sharing the timestamp are one transfer and show as a done "AirDrop received" card with Reveal in Finder. That part needs no Full Disk Access; the sender is not recorded on the file, so it is not shown. Hardened runtime needed `personal-information.addressbook` (and `.calendars`, `.location`, `device.audio-input` for B1/C3/C4) in `Perch.entitlements`.
- **Not verified on hardware yet:** brightness/backlight keys, Bluetooth connect cards, AppleScript fallback, calendar access and the Join flow, camera/mic chips while a sensor is live, a real browser download, the decision card against a live Claude/Codex prompt, every Release C source (Zoom/Meet controls, the notification database and Messages reply, Weather in the pill, live dictation and paste, AirDrop), and the manual matrix in §4.

## 0. Competitor survey

Compiled Oct 30, 2026 from vendor pages and roundups ([notchbay.com](https://notchbay.com/blog/dynamic-island-for-mac/), [notchy.dev](https://notchy.dev/blog/notchnook-vs-boring-notch-vs-alcove/)). Features change; re-check before each release.

| Activity | Boring Notch | NotchNook | Alcove | DynamicLake | Notchy | NotchBay | Pulse Island | Perch v0.1 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Now playing (artwork, waveform, controls) | ✓ | ✓ | ✓ | ✓ | ✓ + lyrics | ✓ | | — |
| Volume / brightness HUD | | | ✓ | ✓ | ✓ | ✓ | | — |
| AirPods / Bluetooth battery on connect | | ✓ | ✓ | ✓ | | ✓ | | — |
| Next meeting + join | | ✓ | | ✓ | | ✓ | | — |
| Call controls (mute, camera, leave) | | | | ✓ | | ✓ | | — |
| Timer / Pomodoro | | | | ✓ | ✓ stats | ✓ | | ✓ timer |
| Camera / mic / screen-recording chips | | | ✓ | | | ✓ | | — |
| Caps Lock chip | | | ✓ | | | | | — |
| Notification mirror + quick reply | | | ✓ | ✓ | | ✓ | | — |
| Download / transfer progress | ✓ shelf | | | ✓ | | | | — |
| AirDrop incoming (accept / decline) | | ✓ | | ✓ | | | | — |
| Weather | | | | | | ✓ | | — |
| Dictation in progress | | | | | | ✓ | | — |
| AI agent status | | | | | usage only | ✓ Claude Code | ✓ | ✓ Claude, Codex, `perch watch` |
| Agent permission approve/deny from the notch | | | | | | ✓ | | — |
| Image conversion batch | | | | | | | | ✓ |

Perch-only today: conversion batches, Codex and generic `perch watch` sessions. Missing everywhere else: media (table stakes), HUDs, battery, calendar, privacy chips, AirDrop.

## 1. Model changes (do first, one PR)

Every source below plugs into the same `ActivityCenter`. The model needs four additions before any source lands.

### 1.1 `Activity.Kind`

```swift
enum Kind: Equatable {
    case timer
    case conversion(batchID: UUID)
    case agent(source: AgentSource, sessionID: String)
    case nowPlaying(bundleID: String)
    case hud(HUDKind)                       // volume, brightness, keyboardBacklight, capsLock
    case deviceBattery(address: String)     // AirPods, Magic Keyboard, …
    case meeting(eventID: String)
    case call(app: CallApp)                 // zoom, meet
    case privacy(PrivacySensor)             // camera, microphone, screen
    case notification(id: String, bundleID: String)
    case download(url: URL)
    case weather
    case airdrop(transferID: String)       // incoming transfer awaiting accept/decline
    case dictation
}
```

### 1.2 `Activity.Progress`

Add `.level(Double)` (volume/brightness bar, battery percent) and `.waveform` (now playing). Keep `.indeterminate`, `.fraction`, `.countdown`, `.paused`.

### 1.3 Presentation class

Not every activity deserves the slot for long. Add `Activity.Presentation`:

| Presentation | Behaviour | Used by |
| --- | --- | --- |
| `.persistent` | Stays until the source ends it | timer, conversion, agent, nowPlaying, call, dictation, download, airdrop |
| `.transient(Duration)` | Shows for the duration, then drops; a repeat resets the clock | hud (1.5 s), deviceBattery (4 s), capsLock (1 s), notification (6 s) |
| `.ambient` | Shown only when nothing else is in the slot; never pulses | weather, meeting (until 10 min before start, then `.persistent` + `needsAttention`) |

`airdrop` and agent permission requests enter as `needsAttention`, so they own the pill until answered.

`ActivityCenter.sorted` becomes: `needsAttention` > transient > `failed` > `done` > persistent running > ambient. A transient HUD preempts the pill for its duration; the previous activity returns when it drops. This is how the iPhone handles a volume change during a Live Activity.

### 1.4 `ActivitySource` protocol and settings

```swift
@MainActor protocol ActivitySource: AnyObject {
    static var id: String { get }          // settings key, e.g. "nowPlaying"
    var permission: Permission { get }     // .none, .needed(kind), .granted, .denied
    func start(center: ActivityCenter)
    func stop()
}
```

`AppSettings` gets `enabledSources: Set<String>`. A new Settings page **Activities** lists every source with a toggle and its permission state (reuse `Settings/SettingsPages.swift` rows). Sources that need a permission are off by default and prompt on first enable. The timer, conversion and agent sources stay always-on; they are features, not sources.

Glance card actions per new kind (extend the table in IMPLEMENTATION_PLAN §2):

| Kind | Glance actions |
| --- | --- |
| nowPlaying | Expanded music card (§3.6): artwork, title, artist, live waveform, scrubber with elapsed / remaining, ⏮ ⏯ ⏭; artwork tap opens the app |
| hud | none (hover does not expand) |
| deviceBattery | none |
| meeting | Join, open in Calendar |
| call | Mute, camera, leave |
| privacy | Reveal app using the sensor |
| notification | Reply (text field), open app, dismiss |
| download | Reveal in Finder, open |
| weather | Open Weather app |
| airdrop | Decline, Accept; file icon + sender avatar in the card |
| dictation | Stop |

## 2. Sources by release

Order is by user value divided by risk. Each row names the macOS API, the permission, and the known trap.

### Release A — table stakes (every competitor has these)

**A1. Now playing.** `MediaRemote` private framework is the only route to a system-wide now-playing state. Since macOS 15.4 non-Apple processes get empty results from `MRMediaRemoteGetNowPlayingInfo`; Boring Notch works around it by spawning a Perl helper that loads the framework under an Apple-signed interpreter (`mediaremote-adapter`). Plan: vendor that adapter as a bundled script, parse its JSON stream, fall back to AppleScript for Music and Spotify when the adapter yields nothing. Controls (`play`, `pause`, `nextTrack`, `previousTrack`, `seekToPlaybackPosition`) go through `MRMediaRemoteSendCommand` via the same adapter. Permission: none. Trap: App Review would reject this; Perch is not sandboxed and not on the App Store (PRD non-goal), so acceptable. Re-test on every macOS point release.

Three surfaces, matching the Dynamic Island music activity:

| Surface | Content | Data |
| --- | --- | --- |
| Compact pill | Artwork (rounded 18 pt) left of the notch, 4-bar waveform right | `kMRMediaRemoteNowPlayingInfoArtworkData`, `PlaybackRate` |
| Expanded card (hover or click) | Artwork 72 pt, title + artist, waveform, scrubber `2:35 ━━━━━━ −1:31`, ⏮ ⏯ ⏭ | `Title`, `Artist`, `ElapsedTime` + `Timestamp` (extrapolated locally at 1 Hz, no polling), `Duration` |
| Home Music module | Same as the card, replaces the Timer module's slot when something is playing | — |

Waveform is a synthetic 4-bar animation driven by `PlaybackRate > 0`, not real audio; real FFT would need an audio tap and Screen Recording permission. Scrubber drag calls `seekToPlaybackPosition`. Card lingers 2 s after the mouse leaves so a control click does not collapse it. Artwork colour (`NSImage` average via `CIAreaAverage`) tints the card background at 12 % opacity.

**A2. Volume / brightness / keyboard-backlight HUD.** Listen for `NX_SYSDEFINED` key events through a `CGEventTap` (needs Accessibility, already requested for island positioning). Read the new level from `AudioObjectGetPropertyData(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)` and `DisplayServicesGetBrightness` (private, `DisplayServices.framework`). Show a `.transient(1.5 s)` `.level` bar. Hiding the stock bezel: competitors unload `com.apple.OSDUIHelper` with `launchctl`; this breaks on SIP-locked systems and comes back after sleep. Plan: offer "Replace system HUD" as a separate toggle, default off, with the launchctl caveat in the row's footnote. Default behaviour is "show beside the notch, keep Apple's bezel".

**A3. Bluetooth device battery.** `IOBluetoothDevice.pairedDevices()` plus IORegistry keys `BatteryPercentLeft`, `BatteryPercentRight`, `BatteryPercentCase`, `BatteryPercentCombined`. Subscribe to `IOBluetoothDeviceConnectNotification` and show a `.transient(4 s)` card on connect; the glance card lists all connected devices. Permission: Bluetooth (TCC prompt on first `IOBluetooth` call). Trap: Magic Keyboard/Mouse report through `AppleDeviceManagementHIDEventService`, not the Bluetooth keys; read both.

**A4. Pomodoro.** Extend the existing timer: `TimerCommand` gains `pomodoro` (25/5 × 4), the Home Timer module gets a Pomodoro preset, and `ActivityCenter.startTimer` accepts a cycle plan. Store completed cycles per day in `UserDefaults` for a streak count in the Timer module. No new API.

### Release B — work layer

**B1. Next meeting.** EventKit `EKEventStore` (Calendar permission, full access). Show the next event as `.ambient` until T−10 min, then `.persistent` with `needsAttention` and a Join action. Join link parsing: `EKEvent.url`, then regex over `notes` and `location` for Zoom (`zoom.us/j/`), Meet (`meet.google.com/`), Teams (`teams.microsoft.com/l/meetup-join`), Webex. Trap: Zoom's `zoommtg://` scheme opens the app directly; prefer it when Zoom is installed.

**B2. Camera / microphone / screen-recording chips.** Camera: CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` listener on every device. Mic: CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on input devices. Both work without permission. Screen recording: no public "someone is recording" API; macOS 15 shows its own purple indicator. Plan: ship camera and mic only, note screen as out of scope until an API appears. Resolving which app uses the sensor needs `/usr/bin/log stream --predicate 'subsystem == "com.apple.TCC"'`, which is heavy; v1 shows the chip without the app name.

**B3. Caps Lock.** `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` (Accessibility already granted for A2). `.transient(1 s)` chip with lock state. Trivial once A2's event tap exists; reuse the tap instead of a second monitor.

**B4. Downloads.** `FSEvents` on `~/Downloads`. Browser partial files: Safari `.download` bundle (progress in its `Info.plist`), Chrome `.crdownload`, Firefox `.part`. Finder copies write `com.apple.progress.fractionCompleted` as an xattr; read it with `getxattr`. Show `.fraction` progress, finish on rename to the final name, `outputs` set so the existing "Reveal in Finder" action works. Permission: none in Perch's non-sandboxed build. Trap: Chrome writes size via sparse file; use the xattr when present, else `st_size / Content-Length` is unknown → `.indeterminate`.

**B5. Agent permission approve/deny.** Today `perch event` is fire-and-forget and `HookInstaller.timeout` is `5` for every hook, so a waiting hook would be killed in 5 s. Claude Code's `PermissionRequest` hook can return a decision on stdout and the agent waits for it. Plan:

1. `HookInstaller` writes `timeout: 120` for the `PermissionRequest` group only; every other group keeps `5`. Already-connected users see "Update Perch's hooks" in Settings → Agents (same diff UI as connect); `AgentConnections` reports `.needsReconnect` when the installed `PermissionRequest` timeout is not `120`.
2. `perch event --await` sends the event, then blocks on the socket for a reply. `AgentBridge` routes Allow / Deny from the glance card back to that connection. The CLI prints exactly:
   ```json
   {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}
   ```
   or `{"behavior": "deny", "message": "Denied from Perch"}`. Deny never sets `interrupt`.
3. No answer within 110 s → the CLI exits 0 with no output, so Claude Code shows its own prompt (exit 2 is ignored on this event). Perch's row drops back to `needsAttention` without the buttons.
4. Fixture `PerchTests/Fixtures/claude-PermissionRequest-reply.json` with the allow shape; a `PerchCLI` test asserts byte-equal output. Codex's `PermissionRequest` hook is documented with the same shape; capture `codex-PermissionRequest.json` and its reply before enabling the buttons for Codex.

This beats NotchBay's version only if it also works for Codex.

### Release C — presence and sharing

**C1. Call controls (Zoom, Meet).** Zoom: AX API over the Zoom window (`AXUIElement`, Accessibility) to press Mute/Video/Leave, or Zoom's global shortcuts (`⌘⇧A`, `⌘⇧V`, `⌘W`) sent via `CGEvent` to the Zoom process. Meet: only reachable through a Chromium browser; NotchBay uses JS injection via AppleScript `execute javascript`, which Chrome disables by default (View → Developer → Allow JavaScript from Apple Events). Plan: Zoom first via shortcuts (robust, no DOM); Meet as a separate toggle with the Chrome setting documented. Detect a call from B2's mic-in-use plus the frontmost bundle ID.

**C2. Notification mirror.** No public API reads other apps' notifications. Competitors read `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (SQLite, needs Full Disk Access) and poll it. Fragile across macOS releases and the schema is undocumented. Plan: ship read-only mirror (title, body, app icon, open app) for Messages only, behind a toggle labelled "experimental", Full Disk Access prompt with an explanation. Quick reply via Messages AppleScript `send "…" to buddy`. Re-evaluate after macOS 27.

**C3. Weather.** Open-Meteo (free, no key) with CoreLocation for the city, or a user-typed city geocoded through `CLGeocoder`. `.ambient` activity: temperature and SF Symbol condition icon in the island when idle. Refresh every 30 min. WeatherKit is the Apple route but needs the paid developer entitlement; keep Open-Meteo unless the account already has it.

**C4. Dictation.** `SpeechAnalyzer` (on-device) with `SpeechTranscriber`, or `DictationTranscriber` for languages it does not support. Hotkey starts a `.persistent` activity with a live waveform from `AVAudioEngine` input levels; stop inserts the text into the frontmost app through the existing `Paster`. Permissions: Microphone.

**C5. AirDrop incoming.** No public API exposes an incoming AirDrop transfer; macOS shows it as a Notification Center alert from `sharingd` with Accept / Decline buttons. Detection: reuse C2's notification DB reader filtered to `com.apple.sharingd` (the record carries sender name and file name; file icon from `NSWorkspace.icon(forFileType:)`, avatar from Contacts when the name matches, Contacts permission). Accept / Decline: `AXUIElement` press on the banner's buttons in `NotificationCenter` (Accessibility). [INFERENCE: the banner's AX tree names the buttons "Accept" / "Decline"; verify on 14, 15, 26 before building.] Activity enters as `needsAttention` with the two buttons from the screenshot layout: AirDrop glyph + avatar, "From <name>", file icon right, Decline (grey) / Accept (blue). Ends when the banner disappears. Outgoing AirDrop (drop a file on the notch → `NSSharingService(named: .sendViaAirDrop)`) is public API and belongs to drop-to-convert's action list, not to this plan. Ships behind the same "experimental" toggle as C2 because it inherits C2's fragility.

### Release D — not planned

- **Synced lyrics** (Notchy): needs a lyrics provider with licensing. Out.
- **Outgoing AirDrop / drop-to-share** (NotchNook, NotchBay): a tray action, not an activity; add to drop-to-convert's action list via `NSSharingService(named: .sendViaAirDrop)` when that list grows.
- **AI usage tracker across providers** (Notchy): overlaps B6; only Claude Code is in scope.

## 3. UI work shared by all sources

1. **Pill renderers per kind.** `IdleActivityContent` switches on `kind` for the compact layout: artwork + waveform (nowPlaying), icon + level bar (hud, deviceBattery), icon + countdown (meeting), icon + dot (privacy), AirDrop glyph + avatar (airdrop). Everything else keeps `ActivityGlyph` + `ActivityTrailing`.
2. **Transient preemption animation.** A `.transient` activity slides in over the current one and slides out; `NotchMotion` gets `hudIn` / `hudOut` (faster than `expand`, 180 ms).
3. **Glance card actions.** `GlanceRow.actions` switches on `kind` per the table in §1.4. Reply needs a text field inside the glance card; the card must stay open while it has focus (change the hover-exit rule in `NotchController`).
4. **Home Activity module.** No change; it already lists `activities.sorted`. Ambient items are hidden from the module and the badge counts.
5. **Settings → Activities page.** One row per source: toggle, permission chip, "Open System Settings" when denied. "Replace system HUD" and "Meet controls" are sub-rows with their caveats.
6. **Music card.** A full-width glance variant for `nowPlaying` (the only kind whose card is not a `GlanceRow` list): 400 × 150 pt, artwork left, title/artist and waveform top right, scrubber row (`elapsed`, track, `−remaining`), transport row centred with ⏯ at 28 pt and ⏮ ⏭ at 22 pt. Replaces the row list when music is the top activity; other activities stay reachable from Home.
7. **Decision card.** Shared layout for `airdrop` and agent `PermissionRequest`: glyph + avatar/icon left, two-line title, optional file icon right, full-width Decline / Accept (or Deny / Allow) buttons below. Esc declines; ↵ accepts; the card does not auto-collapse on mouse-out while a decision is pending.

## 4. Testing

- Unit: `ActivityCenter.sorted` ordering with mixed presentations; transient expiry and reset-on-repeat; `.ambient` never pulses `completionTick`.
- Unit per source: parser tests with fixtures (adapter JSON for A1, IORegistry dumps for A3, calendar notes for B1 link extraction, `Info.plist` and xattr samples for B4, hook reply JSON for B5). Put fixtures under `PerchTests/Fixtures/<source>/`.
- Manual matrix per release on macOS 26 and 27, built-in display and clamshell: each source toggled on, permission denied path, and the slot with three activities (persistent + transient + ambient) at once.
- Energy: a 1-hour idle run with every source enabled, Activity Monitor Energy tab; target under 0.5 % average CPU. The waveform and HUD renderers are the likely offenders; pause the waveform when the pill is off-screen (clamshell with lid closed).

## 5. Risks

| Risk | Mitigation |
| --- | --- |
| `MediaRemote` breaks again on a macOS update | Adapter isolated in one file; AppleScript fallback for Music/Spotify; feature flag to disable remotely via Sparkle appcast note |
| Accessibility/Full Disk Access prompts scare users | Every permission-gated source is off by default; the Activities page explains what each unlocks |
| Notification DB schema changes | Experimental label; silent disable on schema mismatch |
| Perch name collision with the App Store "Perch" notch app (id 6742724228) | Decide before Release A ships; its feature list (media, weather, calendar, timer, clipboard) overlaps this plan |
| Slot crowding | Presentation classes in §1.3 cap what can hold the pill; ambient items never compete |
