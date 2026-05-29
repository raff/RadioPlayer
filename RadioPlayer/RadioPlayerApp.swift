import AVKit
import Foundation
import MediaPlayer
import SwiftUI

@available(macOS 13.0, *)
@main
struct RadioPlayerApp: App {
    @ObservedObject private var nowPlaying: NowPlaying
    private var npCenter: MPNowPlayingInfoCenter?
    private var player: AVPlayer
    private var config: Config?

    @AppStorage("current-station") var current: Int = -1
    @State private var ext = ""
    @State private var adHocStation: Station? = nil
    @State private var adHocTitle: String = ""

    init() {
        let np = NowPlaying()
        _nowPlaying = ObservedObject(wrappedValue: np)

        config = loadConfig()
        player = AVPlayer()
        player.allowsExternalPlayback = true
        npCenter = MPNowPlayingInfoCenter.default()
        npCenter?.playbackState = .stopped

        playerSelect(index: current, play: false)
        setupRemoteControls()
        requestNotifications()
    }

    private func playerPlay() {
        player.play()
        ext = ".fill"
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    private func playerPause() {
        player.pause()
        ext = ""
        MPNowPlayingInfoCenter.default().playbackState = .paused
    }

    private func playerSelect(index: Int, play: Bool) {
        player.currentItem?.remove(nowPlaying.output)
        adHocStation = nil
        adHocTitle = ""

        if index < 0 || index >= config!.station.count || config?.station[index].url == "" {
            player.replaceCurrentItem(with: nil)
            playerPause()
            nowPlaying.reset()
            current = -1
            return
        }

        current = index

        let station = config!.station[index]
        station.songTitle = ""
        updateNpInfo(station: station)
        nowPlaying.reset()

        let item = AVPlayerItem(url: URL(string: station.url)!)
        item.add(nowPlaying.output)
        player.replaceCurrentItem(with: item)

        nowPlaying.onSongChanged = { songTitle in
            station.songTitle = songTitle
            updateNpInfo(station: station, songTitle: songTitle)
            notify(title: station.title, message: songTitle)
        }

        if play { playerPlay() }
    }

    private func playAdHoc(urlString: String, name: String) {
        guard let url = URL(string: urlString) else { return }

        player.currentItem?.remove(nowPlaying.output)

        // Use the hostname as a display name for HLS/non-ICY streams until we know better
        let fallback = url.host ?? urlString
        let station = Station(title: name.isEmpty ? fallback : name, url: urlString)
        adHocStation = station
        adHocTitle = station.title
        current = -1

        updateNpInfo(station: station)
        nowPlaying.reset()

        let item = AVPlayerItem(url: url)
        item.add(nowPlaying.output)
        player.replaceCurrentItem(with: item)

        nowPlaying.onSongChanged = { songTitle in
            station.songTitle = songTitle
            updateNpInfo(station: station, songTitle: songTitle)
            notify(title: station.title, message: songTitle)
        }

        playerPlay()

        // Try to get the station name from ICY headers if none was given
        if name.isEmpty {
            fetchStationName(urlString: urlString) { detected in
                if let n = detected, !n.isEmpty {
                    adHocTitle = n
                    station.title = n
                    updateNpInfo(station: station)
                }
            }
        }
    }

    private func fetchStationName(urlString: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")

        let delegate = ICYHeaderDelegate(completion)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        delegate.task = session.dataTask(with: request)
        delegate.task?.resume()
    }

    private func showPlayURLDialog() {
        let recentURLs = ConfigStore.shared.recentURLs

        let alert = NSAlert()
        alert.messageText = "Play Radio Station"
        alert.informativeText = "Enter the stream URL:"
        alert.addButton(withTitle: "Play")
        alert.addButton(withTitle: "Cancel")

        let urlField: NSTextField
        if recentURLs.isEmpty {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = "https://stream.example.com/radio"
            urlField = field
        } else {
            let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            combo.placeholderString = "https://stream.example.com/radio"
            combo.addItems(withObjectValues: recentURLs)
            urlField = combo
        }

        alert.accessoryView = urlField
        alert.window.initialFirstResponder = urlField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let urlString = urlField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !urlString.isEmpty else { return }
            ConfigStore.shared.addURL(urlString)
            playAdHoc(urlString: urlString, name: "")
        }
    }

    private func showAddToConfigDialog() {
        guard let station = adHocStation else { return }

        let suggestedName = adHocTitle == station.url ? "" : adHocTitle

        let alert = NSAlert()
        alert.messageText = "Add Station to Configuration"
        alert.informativeText = station.url
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        nameField.stringValue = suggestedName
        nameField.placeholderString = "Station name"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            adHocTitle = name
            appendToConfig(title: name, url: station.url)
            if let updated = loadConfig() {
                config!.update(c: updated)
            }
        }
    }

    private func isSelected(i: Int) -> Bool {
        return current == i
    }

    private func selectNext(forward: Bool) -> Int {
        let step = forward ? 1 : -1
        var index = current

        for _ in 1...config!.station.count {
            index += step

            if index >= config!.station.count {
                index = 0
            } else if index < 0 {
                index = config!.station.count - 1
            }

            if config!.station[index].title != "" {
                return index
            }
        }

        return -1
    }

    private func playNext() {
        let index = selectNext(forward: true)
        playerSelect(index: index, play: true)
    }

    private func currentTitle() -> String {
        if adHocStation != nil && current < 0 {
            return adHocTitle
        }
        let curr = current
        if curr < 0 || curr >= config!.station.count {
            return ""
        }
        return config!.station[curr].title
    }

    private func setupRemoteControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.pauseCommand.addTarget { _ in
            NSLog("remote pause")
            notify(title: config!.title, message: "Pause")
            playerPause()
            return .success
        }
        commandCenter.playCommand.addTarget { _ in
            NSLog("remote play")
            if player.currentItem == nil && current < 0 {
                playNext()
            } else {
                playerPlay()
            }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            NSLog("remote playPause")
            if player.timeControlStatus == .playing {
                notify(title: config!.title, message: "Pause " + currentTitle())
                playerPause()
            } else {
                if player.currentItem == nil && current < 0 {
                    playNext()
                } else {
                    playerPlay()
                }
                notify(title: config!.title, message: "Play " + currentTitle())
            }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { _ in
            NSLog("remote next")
            let index = selectNext(forward: true)
            playerSelect(index: index, play: true)
            notify(title: config!.title, message: "Play " + currentTitle())
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { _ in
            NSLog("remote prev")
            let index = selectNext(forward: false)
            playerSelect(index: index, play: true)
            notify(title: config!.title, message: "Play " + currentTitle())
            return .success
        }
    }

    private func reloadConfig() {
        if let updated = loadConfig() {
            config!.update(c: updated)
            playerSelect(index: -1, play: false)
        }
    }

    private func updateNpInfo(station: Station, songTitle: String = "") {
        npCenter?.nowPlayingInfo = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
            MPMediaItemPropertyTitle: songTitle.isEmpty ? station.title : songTitle,
            MPMediaItemPropertyArtist: songTitle.isEmpty ? "" : station.title,
            MPMediaItemPropertyPodcastTitle: station.title,
            MPNowPlayingInfoPropertyAssetURL: URL(string: station.url) as Any,
        ]
    }

    var body: some Scene {
        MenuBarExtra(String("Radio"), systemImage: "radio\(ext)") {
            if !nowPlaying.songTitle.isEmpty {
                Label(nowPlaying.songTitle, systemImage: "music.note")
                    .foregroundStyle(.secondary)
                    .disabled(true)
                Divider()
            }

            Button("Play/Pause") {
                if player.timeControlStatus == .paused {
                    if player.currentItem == nil && adHocStation == nil && current < 0 {
                        playNext()
                    } else {
                        playerPlay()
                    }
                } else {
                    playerPause()
                }
            }.keyboardShortcut("P")

            Button("Prev") {
                let index = selectNext(forward: false)
                playerSelect(index: index, play: true)
            }.keyboardShortcut("B")

            Button("Next") {
                let index = selectNext(forward: true)
                playerSelect(index: index, play: true)
            }.keyboardShortcut("N")

            Divider()

            ForEach(0..<config!.station.count, id: \.self) { index in
                let station = config!.station[index]

                if station.title == "" {
                    Divider()
                } else {
                    Button {
                        playerSelect(index: index, play: true)
                    } label: {
                        let icon = player.timeControlStatus == .paused ? "play" : "play.fill"
                        Image(systemName: isSelected(i: index) ? icon : "pause")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.title)
                            if isSelected(i: index) && !nowPlaying.songTitle.isEmpty {
                                Text(nowPlaying.songTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if adHocStation != nil {
                Divider()
                Label(adHocTitle, systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                    .disabled(true)
                Button("Add to Configuration...") {
                    showAddToConfigDialog()
                }
            }

            Divider()

            Button("Play URL...") {
                showPlayURLDialog()
            }.keyboardShortcut("U")

            Menu("Settings...") {
                Button("Edit configuration") {
                    editConfig(doneHandler: reloadConfig)
                }
                Button("Reload") {
                    reloadConfig()
                }
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }.keyboardShortcut("q")
        }
    }
}
