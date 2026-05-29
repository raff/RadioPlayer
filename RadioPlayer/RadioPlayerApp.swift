//
//  RadioPlayerApp.swift
//  RadioPlayer
//
//  Created by Raffaele Sena on 10/17/22.
//

import SwiftUI
import AVKit
import MediaPlayer
import Foundation
import UserNotifications
import TOMLDecoder

class Station : Codable {
    let title: String
    let url: String
    var songTitle: String = ""

    private enum CodingKeys: String, CodingKey {
        case title, url
    }
}

class Config : Codable {
    var title: String
    var station: [Station]

    func update(c: Config) {
        title = c.title
        station = c.station
    }
}

func loadConfig() -> Config? {
    guard let url = Bundle.main.url(forResource: "radio", withExtension: "conf") else {
        NSLog("Configuration file not found: radio.conf")
        return nil
    }

    do {
        let data = try Data(contentsOf: url)
        return try TOMLDecoder().decode(Config.self, from: data)
    } catch {
        NSLog("Failed to decode radio.conf: %@", error.localizedDescription)
        return nil
    }
}

class Observer: NSObject {
    let completion: (() -> Void)?
    init(_ completion: (() -> Void)?) {
        self.completion = completion
    }
    // swiftlint:disable block_based_kvo
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        completion?()
    }
    // swiftlint:enable block_based_kvo
}

func editConfig(doneHandler: (() -> Void)?) {
    guard let url = Bundle.main.url(forResource: "radio", withExtension: "conf") else {
        NSLog("Configuration file not found: radio.conf")
        return
    }

    guard let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
        NSLog("TextEdit not found")
        return
    }

    let openConf = NSWorkspace.OpenConfiguration()
    openConf.activates = true
    openConf.createsNewApplicationInstance = true

    NSWorkspace.shared.open([url], withApplicationAt: appUrl, configuration: openConf) { app, err in
        NSLog("edit started")

        if app != nil && doneHandler != nil {
            let listener = Observer {
                NSLog("calling handler")
                doneHandler!()
            }
            app!.addObserver(listener, forKeyPath: "isTerminated", context: nil)
            app!.removeObserver(listener, forKeyPath: "isTerminated")
        }
    }
}

func requestNotifications() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, /* .sound, .badge,*/ .provisional]) { granted, error in
        if error != nil {
            NSLog("UN requestAuthoriziation %@", error!.localizedDescription)
        } else {
            NSLog("UN requestAuthorization %@", granted ? "granted" : "denied")
        }
    }
}

func notify(title : String, message : String) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
        guard (settings.authorizationStatus == .authorized) ||
              (settings.authorizationStatus == .provisional) else {
            NSLog("Notifications not authorizided nor provisional")
            return

        }

        if settings.alertSetting == .enabled {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.categoryIdentifier = "com.github.raff.radio.RadioPlayer"

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            center.add(request)
        } else {
            NSLog("Alert notifications are disabled")
        }
    }
}

// Receives timed metadata from the stream and publishes the current song title.
// Handles both ICY (Icecast StreamTitle) and HLS/ID3 (common title identifier).
class NowPlaying: NSObject, ObservableObject, AVPlayerItemMetadataOutputPushDelegate {
    @Published var songTitle = ""
    var onSongChanged: ((String) -> Void)?

    let output: AVPlayerItemMetadataOutput

    override init() {
        output = AVPlayerItemMetadataOutput(identifiers: nil)
        super.init()
        output.setDelegate(self, queue: .main)
    }

    func reset() {
        songTitle = ""
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        for group in groups {
            for item in group.items {
                guard let value = item.stringValue ?? (item.value as? String),
                      !value.isEmpty else { continue }

                // ICY StreamTitle — Icecast
                if let key = item.key as? String, key == "StreamTitle" {
                    update(title: value); return
                }
                // Common title (used by some HLS streams)
                if item.identifier == .commonIdentifierTitle {
                    update(title: value); return
                }
                // ID3 TIT2 — title tag embedded in HLS segments
                if item.identifier?.rawValue == "id3/TIT2" {
                    update(title: value); return
                }
            }
        }
    }

    private func update(title: String) {
        if songTitle != title {
            songTitle = title
            onSongChanged?(title)
        }
    }
}

@available(macOS 13.0, *)
@main
struct RadioPlayerApp: App {
    @ObservedObject private var nowPlaying: NowPlaying
    private var npCenter : MPNowPlayingInfoCenter?
    private var player : AVPlayer
    private var config : Config?

    @AppStorage("current-station") var current : Int = -1
    @State private var ext = ""

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
        self.player.play()
        ext = ".fill"
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    private func playerPause() {
        self.player.pause()
        ext = ""
        MPNowPlayingInfoCenter.default().playbackState = .paused
    }

    private func playerSelect(index: Int, play: Bool) {
        player.currentItem?.remove(nowPlaying.output)

        if index < 0 || index > config!.station.count || config?.station[index].url == "" {
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

        let npRef = npCenter
        nowPlaying.onSongChanged = { songTitle in
            station.songTitle = songTitle
            updateNpInfo(station: station, songTitle: songTitle)
            notify(title: station.title, message: songTitle)
        }

        if play {
            playerPlay()
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

            if config!.station[index].title != "" { // divider
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
        let curr = current
        if curr < 0 || curr >= config!.station.count {
            return ""
        }

        return config!.station[curr].title
    }

    private func setupRemoteControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.pauseCommand.addTarget { (event) -> MPRemoteCommandHandlerStatus in
            NSLog("remote pause")
            notify(title: config!.title, message: "Pause")
            playerPause()
            return .success
        }
        commandCenter.playCommand.addTarget { (event) -> MPRemoteCommandHandlerStatus in
            NSLog("remote play")
            if current < 0 {
                playNext()
            } else {
                playerPlay()
            }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { (event) -> MPRemoteCommandHandlerStatus in
            NSLog("remote playPause")
            if player.timeControlStatus == .playing {
                notify(title: config!.title, message: "Pause " + currentTitle())
                playerPause()
            } else {
                if current < 0 {
                    playNext()
                } else {
                    playerPlay()
                }

                notify(title: config!.title, message: "Play " + currentTitle())
            }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { (event) -> MPRemoteCommandHandlerStatus in
            NSLog("remote next")
            let index = selectNext(forward: true)
            playerSelect(index: index, play: true)
            notify(title: config!.title, message: "Play " + currentTitle())
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { (event) -> MPRemoteCommandHandlerStatus in
            NSLog("remote next")
            let index = selectNext(forward: false)
            playerSelect(index: index, play: true)
            notify(title: config!.title, message: "Play " + currentTitle())
            return .success
        }
    }

    private func reloadConfig() {
        let updated = loadConfig()
        if updated != nil {
            config!.update(c: updated!)
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
                    if current < 0 {
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

            Divider()

            Menu("Settings...") {
                Button("Edit configuration") {
                    editConfig(doneHandler: reloadConfig)
                }

                Button("Reload ") {
                    reloadConfig()
                }
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }.keyboardShortcut("q")
        }
    }
}
