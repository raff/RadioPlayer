# RadioPlayer

A macOS menu bar app for streaming online radio stations. Lives in the status bar, stays out of the way, and hands off to the system media controls so you can play, pause, and skip from the keyboard or Touch Bar without opening the menu.

## Requirements

- macOS 13 Ventura or later
- Xcode 14+ (to build from source)

## Building

```sh
make install
```

This produces a release build and places the app at `inst/Applications/RadioPlayer.app`. Copy it to `/Applications` or run it directly from there.

To build without installing:

```sh
make build
```

## Installation

Copy `RadioPlayer.app` to `/Applications` and launch it. On first run, the app copies its default station list to `~/Library/Application Support/RadioPlayer/radio.conf` — your edits there survive app updates.

## Usage

Click the radio icon in the menu bar to open the station menu.

### Playback controls

| Action | Keyboard shortcut |
|--------|------------------|
| Play / Pause | `P` |
| Previous station | `B` |
| Next station | `N` |
| Play from URL | `U` |
| Quit | `Q` |

The system media keys (play/pause, next, previous) and Touch Bar controls also work while the menu is closed.

### Playing a station

Select any station from the list to start streaming. The currently playing station is highlighted. If a song title is available from the stream metadata it appears at the top of the menu and below the station name.

### Playing from a URL

Press `U` (or choose **Play URL...**) to enter any stream URL directly. Supported formats:

- Icecast / Shoutcast streams (`http://…`)
- HLS playlists (`.m3u8`)

The app reads the station name from the `icy-name` response header when available. For HLS streams where that header is absent it falls back to the hostname. The last 5 URLs you played appear in a dropdown for quick re-use.

While an ad-hoc station is playing, click **Add to Configuration...** to save it to your permanent station list.

### Configuring stations

Choose **Settings... › Edit configuration** to open the config file in TextEdit. The station list reloads automatically when you close the editor.

Stations are defined in [TOML](https://toml.io) format:

```toml
title = "My Radio"

[[station]]
title = "Station Name"
url   = "https://stream.example.com/radio"

[[station]]
title = ""   # empty title and url = divider line in the menu
url   = ""
```

The config file lives at:

```
~/Library/Application Support/RadioPlayer/radio.conf
```

You can edit it with any text editor. Changes take effect after choosing **Settings... › Reload** or restarting the app.

## Now Playing and notifications

The app publishes the current station and song title to the macOS Now Playing widget (Control Center, Lock Screen, Touch Bar). It also sends a notification banner each time the song title changes — grant notification permission when prompted, or enable it later in **System Settings › Notifications**.

## License

See [LICENSE](LICENSE).
