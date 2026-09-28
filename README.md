# What Made That Sound

A native macOS app that keeps a log of which apps start and stop playing audio, so
when something dings, chirps or starts talking you can find out what it was.

- **Event-driven.** A background agent subscribes to Core Audio's per-process
  objects and is notified the moment any process starts or stops producing output.
  Nothing polls.
- **Knows who's responsible.** Audio is often rendered by helpers (`Google Chrome
  Helper`, `com.apple.WebKit.GPU`, XPC services); sounds are attributed to the app
  that owns the helper, with the helper, PID and output device alongside.
- **Bounded history.** Events go into a 200 MB on-disk ring buffer; once it's full,
  the oldest events are dropped automatically.
- **Always on, never in the way.** The recorder is a LaunchAgent that starts at login
  and is restarted by launchd if it ever exits. The viewer is an ordinary app you
  open when you want to look, and quit when you're done.

## Requirements

- macOS 14.2 or later (Core Audio process objects). Developed on macOS 27.
- Xcode 16 or later / Swift 6. Developed with Xcode 27 and Swift 6.4.

## Build, install, run

```sh
make            # builds "build/What Made That Sound.app" (release, ad-hoc signed)
make test       # unit tests + a live Core Audio test that plays a *silent* sound
make install    # copies the app to /Applications and opens it
make status     # is the agent registered and running? how full is the log?
make uninstall  # turns off background recording and removes the app
```

The first time the app runs it turns on background recording. Use **Settings (⌘,)**
to turn it off or on again, see how much of the log is used, or clear the history.
Recorded history lives in `~/Library/Application Support/WhatMadeThatSound/` and is
kept when the app is uninstalled.

You can also open `WhatMadeThatSound.xcodeproj` in Xcode. If `xcodebuild` reports that
a plug-in failed to load, Xcode's first-launch components aren't installed yet: open
Xcode once, or run `sudo xcodebuild -runFirstLaunch`. `make` doesn't need them; it
builds with SwiftPM and assembles the bundle itself (`scripts/build-app.sh`).

### Signing

Builds are ad-hoc signed by default, which is fine on the Mac that built them. With an
ad-hoc signature, launchd pins the registered agent to the exact binary it saw at
registration, so after installing a new build the agent can't start until the app
registers it again. The app does this by itself the next time it's opened (`make
install` opens it for you). Signing with a Developer ID avoids the issue entirely:

```sh
make SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

Keep only one copy of the app around: another copy with the same bundle identifier
can take over the agent's registration.

## Using the viewer

- The sidebar lists **All Activity** and every day with sounds, newest first, with counts.
- The table shows one row per sound: when it started and ended, how long it lasted,
  the application, the process that actually played it (with PID), and the output
  device. Sounds still playing show a live timer. Click a column to sort.
- **Search** matches app names, bundle identifiers, process names, executable paths,
  PIDs and device names; every word must match. The sidebar then shows only the days
  with matches.
- Select a row and press the details button (or double-click) for everything that
  was recorded about it. Right-click to copy rows, reveal the app in Finder, or show
  only that app's sounds.
- A banner explains when sounds aren't being recorded and offers the fix.

## Command line

The agent binary doubles as a command-line tool for the log:

```sh
AGENT="/Applications/What Made That Sound.app/Contents/MacOS/WhatMadeThatSoundAgent"
"$AGENT" status            # agent running? log size and record count
"$AGENT" dump --limit 20   # the 20 most recent events
"$AGENT" follow            # print events as they're recorded
"$AGENT" clear             # delete the history (recording continues)
```

```
2026-09-28 02:08:23.893  ● monitoring started (agent 1.0, pid 17418); default output: MacBook Pro Speakers
2026-09-28 02:08:47.547  ▶ started   Terminal (afplay, pid 17786) → MacBook Pro Speakers
2026-09-28 02:08:48.873  ■ stopped   Terminal (afplay, pid 17786) after 1.3 s (process exited)
```

The app itself accepts `--agent-status`, `--register-agent` and `--unregister-agent`
for scripts (only the app can add or remove its own background item).

## How it works

```
                        Core Audio HAL (coreaudiod)
                                  │  property-change notifications
                                  ▼
 ┌──────────────── WhatMadeThatSoundAgent (LaunchAgent) ─────────────────┐
 │ AudioActivityMonitor ──► EventRecorder ──► RingLog (events.ringlog)   │
 │   listeners on process list,     batches writes      200 MB ring      │
 │   each process's IsRunning/        off the monitor    buffer file     │
 │   IsRunningOutput/Devices          queue                              │
 └───────────────┬───────────────────────────────────────────────────────┘
                 │ notify_post("…logChanged")          agent.lock (fcntl lock)
                 ▼                                              ▲ F_GETLK: running?
 ┌──────────────────── What Made That Sound.app ─────────────────────────┐
 │ LogStore: reads new records only ──► SessionAssembler ──► SwiftUI     │
 │ ServiceController: SMAppService.agent(plistName:) register/unregister │
 └───────────────────────────────────────────────────────────────────────┘
```

**Monitoring.** Since macOS 14.2 the HAL exposes a *process object* for every client of
the audio server. The agent listens to `kAudioHardwarePropertyProcessObjectList` to learn
about processes as they connect and disconnect, and to each process object's
`IsRunningOutput`, `IsRunning` and output `Devices` properties (on current macOS,
`IsRunningOutput` changes arrive via the other two). A session starts when a process's
output starts and ends when it stops, or when the process exits. Core Audio publishes the
device list a few milliseconds after the stream starts, so the start event is written
after a 100 ms settle delay but stamped with the real start time. The monitor also
records the default output device, audio server restarts, and its own start and stop,
so the viewer can tell "still playing" apart from "recording stopped". No permissions
are needed: the agent reads activity metadata and never touches audio samples.

**Attribution.** Each process is resolved once, when it connects: executable path,
bundle identifier, and the process macOS holds *responsible* for it
(`responsibility_get_pid_responsible_for_pid`, private but long-stable and what TCC
uses). Its owning `.app` gives the name and icon shown in the viewer; if the lookup
isn't available, the outermost `.app` around the executable is used instead.

**Storage.** `events.ringlog` is a single file: a 4 KB header region followed by a
200 MiB data region used circularly. Records are variable-length, 8-byte aligned and
CRC32-checked; each carries a sequence number and a compact binary event (tagged fields,
so the format can grow). Positions are 64-bit logical offsets that only increase, so a
reader can resume exactly where it stopped. Every operation takes a brief `flock`; appends
first commit any eviction to the header, then write records, then publish them by
advancing the head, with write barriers in between, so a crash can never leave the
header pointing at garbage. The header is written alternately to two CRC-protected slots.
On open, the agent re-validates the log and drops any torn tail; readers skip damaged
bytes by resynchronising on the next valid record.

**Live updates.** After each write the agent posts a Darwin notification. The viewer
reads only the records past its last position and folds them into its sessions. The
viewer loads the whole log once in the background: a full 200 MB log (about 720,000
events) loads in under a second.

**Service management.** The agent's LaunchAgent plist is embedded in the app bundle
(`Contents/Library/LaunchAgents`) and registered with `SMAppService`, so it appears
under System Settings › General › Login Items and survives reboots (`RunAtLoad`,
`KeepAlive`). The agent holds a POSIX lock on `agent.lock` while running, which gives
single-instance behaviour and lets the viewer ask the kernel whether an agent is alive
(`F_GETLK`) without polling or talking to launchd.

## Limitations

- "Playing" means the process has an active output stream. Some apps keep a stream open
  while silent — browsers for a few seconds after a video pauses, games, call apps for
  the whole call — so a session can be longer than what you heard.
- Alert and notification sounds are played by system daemons (e.g.
  `systemsoundserverd`), so the log shows the daemon rather than the app that asked
  for the sound.
- The ring buffer's size is fixed when the log is created.

## Project layout

```
WhatMadeThatSound/          viewer app (SwiftUI)
WhatMadeThatSoundAgent/     background agent / CLI (main.swift)
LaunchAgents/               LaunchAgent plist embedded in the app bundle
Packages/WhatMadeThatSoundKit/
  Sources/…/Monitor/        Core Audio monitoring, attribution, event recorder
  Sources/…/Storage/        ring buffer, binary event codec
  Sources/…/Model/          events, sessions, formatting, sample data
  Sources/…/Shared/         paths, identifiers, Darwin notifications, agent lock
  Tests/                    Swift Testing suites
WhatMadeThatSound.xcodeproj Xcode project (synchronized folders)
Package.swift, scripts/     command-line build of the same sources
```

## Development notes

- Try the viewer on synthetic data without touching your real log:

  ```sh
  AGENT="build/What Made That Sound.app/Contents/MacOS/WhatMadeThatSoundAgent"
  "$AGENT" generate-sample-log --data-dir /tmp/wmts --events 5000 --days 30
  open -n --env WMTS_DATA_DIR=/tmp/wmts "build/What Made That Sound.app"
  ```

  With `WMTS_DATA_DIR` set, the app never registers the agent.
- Debug builds (`CONFIGURATION=debug make`) have a snapshot mode: with
  `WMTS_SNAPSHOT_DIR` set, the app walks through a few UI states, writes a PNG of each
  window there, and quits.
- Logs: `log stream --level info --predicate 'subsystem == "com.matthewy.WhatMadeThatSound"'`.
- Run the agent in a terminal: `WhatMadeThatSoundAgent run --verbose --data-dir /tmp/wmts`.
