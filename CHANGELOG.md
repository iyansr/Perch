# perch

## 0.3.3

### Patch Changes

- [`856fcad`](https://github.com/iyansr/Perch/commit/856fcad43c692c82a5bb9a3a3f0118d0e74c858a) Thanks [@iyansr](https://github.com/iyansr)! - Calendar works better with a mouse: drag the day ribbon or the timeline to scroll them, and flick to keep them moving. Shift + scroll wheel now scrolls the timeline sideways too, as it already did the ribbon. Clicking a day or event still selects it; the release at the end of a drag does not.

## 0.3.2

### Patch Changes

- [`8bffdff`](https://github.com/iyansr/Perch/commit/8bffdff680412d21c618ff3cf78af5feef653ef5) Thanks [@iyansr](https://github.com/iyansr)! - Opening Calendar shows today straight away instead of sometimes sliding the day ribbon across from a year back.

## 0.3.1

### Patch Changes

- [`4272f34`](https://github.com/iyansr/Perch/commit/4272f340ddc58667ab73e6018bdc201a2d061dd5) Thanks [@iyansr](https://github.com/iyansr)! - The Calendar timeline now covers the whole day: scroll sideways to see midnight to 6 AM. It opens at 6 AM, or earlier when the day has an earlier event, and always keeps the current time in view on today. Early events are regular blocks instead of a "Before 6 AM" row.
  
  Scrolling the day ribbon is smoother: it no longer redraws the page or reformats dates as days pass the centre, and its edge fades no longer re-render the strip each frame.

## 0.3.0

### Minor Changes

- [`8da1d97`](https://github.com/iyansr/Perch/commit/8da1d97275efe390143b44cb30733ca6422454b5) Thanks [@iyansr](https://github.com/iyansr)! - Add a Calendar page to Home: a scrollable ribbon of days, the selected day as a timeline, and the event's details with Join for Zoom, Meet and Teams. Click the month to jump to any month of any year; the arrow keys step by day or week. It is also a command: search "Calendar" or "schedule", or give it a shortcut in Settings → Shortcuts. Needs Calendar access.
  
  Settings → General → 24-hour time shows calendar times as 20:00 instead of 8:00 PM; it starts on your region's clock.

## 0.2.0

### Minor Changes

- [`74581ed`](https://github.com/iyansr/Perch/commit/74581ed745b841bacab4037c54f0db4f628c1a16) Thanks [@iyansr](https://github.com/iyansr)! - Add a Dev Servers page to Home: every local server you started (Next.js, Vite, Django, Rails, Postgres and more) with its port and project folder. Open one in the browser, or stop it after a confirmation. Apps, system services and coding-agent helpers are left out. It is also a command: search "Dev Servers" or "ports", or give it a shortcut in Settings → Shortcuts.
  
  Home and its pages are wider (600 pt) so the dashboard tiles have more room; the search panel keeps its width.

## 0.1.6

### Patch Changes

- [#4](https://github.com/iyansr/Perch/pull/4) [`efc22b9`](https://github.com/iyansr/Perch/commit/efc22b9498d06031e4de371aebfb9321c3714d16) Thanks [@iyansr](https://github.com/iyansr)! - Answer Claude's questions from Perch: an `AskUserQuestion` prompt now shows its options, and picking one answers it in the terminal session. Approving a plan from Perch also takes effect now.

## 0.1.5

### Patch Changes

- [`4db78bd`](https://github.com/iyansr/Perch/commit/4db78bd7367702f447880222667a9d52f82fb6cc) Thanks [@iyansr](https://github.com/iyansr)! - Fix a crash at launch when a Bluetooth device is connected and the Bluetooth Battery source is on.

## 0.1.4

### Patch Changes

- [`258d814`](https://github.com/iyansr/Perch/commit/258d81421c4d13943db1614c8c14ad72d4fd954a) Thanks [@iyansr](https://github.com/iyansr)! - Add native updates. Perch checks for new stable releases once a day (on by default, with an off switch) and under Settings → Check for Updates. It downloads, installs and relaunches only after you approve. Releases now ship a signed `Perch-<version>.zip` alongside the DMG. The first release with the updater must be installed manually.

## 0.1.3

### Patch Changes

- [`8799074`](https://github.com/iyansr/Perch/commit/8799074005b4b8f3d22f498145d62bae687656c2) Thanks [@iyansr](https://github.com/iyansr)! - Hide paused or stopped media after five minutes, even without further player updates. Add an adjustable 1–60 minute timeout under Settings → Activities → Now Playing. Repeated paused updates no longer keep media visible indefinitely; playback restores it, and an empty player state hides it immediately.

- [`8799074`](https://github.com/iyansr/Perch/commit/8799074005b4b8f3d22f498145d62bae687656c2) Thanks [@iyansr](https://github.com/iyansr)! - Add Settings → General → Open at login, with macOS Login Items approval handling and error messages.

## 0.1.2

### Patch Changes

- Publish the Homebrew cask from the release workflow.

## 0.1.1

### Patch Changes

- First release: signed universal DMG, Homebrew cask, and automated releases.
