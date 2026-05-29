# Implementation notes

## Source files

The app is written entirely in Swift using SwiftUI. The source is split into four files under `RadioPlayer/`:

| File | Responsibility |
|------|---------------|
| `Models.swift` | `Station` and `Config` data classes decoded from the TOML config |
| `ConfigStore.swift` | Config file I/O (read, write, open in editor), recent-URL persistence |
| `NowPlaying.swift` | Stream metadata extraction, system notifications, ICY header probing |
| `RadioPlayerApp.swift` | App entry point, player lifecycle, menu bar UI |

## Key design decisions

### MenuBarExtra

The UI is a `MenuBarExtra` scene (macOS 13+). This means the whole app is the menu — there are no windows. Keyboard shortcuts defined on `Button` views with `.keyboardShortcut` only fire when the menu is open, which is fine for this use case.

### Audio playback

`AVPlayer` handles all streaming. For each station it creates a new `AVPlayerItem` from the stream URL, which AVFoundation resolves automatically whether the URL points to an Icecast stream, an HLS `.m3u8` playlist, or a plain audio file.

### Config file location

The bundle ships a default `radio.conf` as a resource. On first launch, `configFileURL()` copies it to `~/Library/Application Support/RadioPlayer/radio.conf`, which is the writable path used for all subsequent reads and writes. This avoids writing into the app bundle (which fails under sandboxing and in production builds) and means user edits survive app updates.

### Station name detection

Two mechanisms run in sequence when playing a URL entered manually:

1. **ICY headers** — an `ICYHeaderDelegate` (URLSessionDataDelegate) opens a short-lived connection to the stream URL with the `Icy-MetaData: 1` request header. If the server returns an `icy-name` header the connection is cancelled immediately after to avoid buffering audio data. This works for most Icecast/Shoutcast streams.

2. **Hostname fallback** — for HLS streams and any server that does not send ICY headers, the display name falls back to the URL's hostname (`URL.host`). This is always better than showing the raw URL.

If the ICY name arrives after playback has already started (the fetch is async), `adHocTitle` and the station's `title` property are both updated and `updateNpInfo` is called again so the Now Playing widget reflects the correct name.

### Song title (timed metadata)

`NowPlaying` implements `AVPlayerItemMetadataOutputPushDelegate`. It checks three identifier types because different stream formats embed the current song in different ways:

- `StreamTitle` key (string key comparison) — Icecast ICY in-stream metadata
- `.commonIdentifierTitle` — used by some HLS streams
- `id3/TIT2` — ID3 title tag embedded in HLS segments

### Now Playing integration

`MPNowPlayingInfoCenter` receives updated info on every station switch and every song-title change. This populates the Control Center widget, the Lock Screen panel, and the Touch Bar. `MPRemoteCommandCenter` registers handlers for play, pause, toggle, next, and previous so media keys work system-wide even when the menu is closed.

The remote `playCommand` handler checks `player.currentItem == nil && current < 0` (rather than just `current < 0`) so that resuming a paused ad-hoc stream works correctly and doesn't jump to the first configured station.

### Recent URLs

`ConfigStore` is a simple singleton that stores the last five manually entered URLs in `UserDefaults` under the `"recent-urls"` key. `showPlayURLDialog` renders an `NSComboBox` (a subclass of `NSTextField`, so `.stringValue` still works for reading the entered text) when the list is non-empty, falling back to a plain `NSTextField` otherwise.

### Dialog window ordering

Both `showPlayURLDialog` and `showAddToConfigDialog` call `NSApp.activate(ignoringOtherApps: true)` immediately before `alert.runModal()`. Without this the modal appears behind any other foreground window because the menu bar app has no main window to anchor it.

### TOML config writing

When appending a new station, the title string is sanitised before embedding it in a TOML double-quoted string:

- `\` → `\\`
- `"` → `\"`
- newlines and carriage returns → space

This keeps the config file valid regardless of what the user types in the name field.

### State reactivity

`Station` is a reference type (`class`), so mutating `station.title` does not trigger SwiftUI re-renders. A separate `@State private var adHocTitle` is used as the reactive source of truth for the menu label and the "Add to Configuration..." pre-fill. `station.title` is kept in sync for the Now Playing info dictionary.
