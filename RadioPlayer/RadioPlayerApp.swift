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
    var title: String
    var url: String
    var songTitle: String = ""

    init(title: String, url: String) {
        self.title = title
        self.url = url
    }

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

// Returns the writable config path in Application Support, copying the bundle default on first launch.
func configFileURL() -> URL? {
    let fm = FileManager.default
    guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return Bundle.main.url(forResource: "radio", withExtension: "conf")
    }

    let appDir = appSupport.appendingPathComponent("RadioPlayer")
    let configURL = appDir.appendingPathComponent("radio.conf")

    if !fm.fileExists(atPath: configURL.path) {
        do {
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            if let bundleURL = Bundle.main.url(forResource: "radio", withExtension: "conf") {
                try fm.copyItem(at: bundleURL, to: configURL)
            }
        } catch {
            NSLog("Failed to initialise config in Application Support: %@", error.localizedDescription)
            return Bundle.main.url(forResource: "radio", withExtension: "conf")
        }
    }

    return configURL
}

func loadConfig() -> Config? {
    guard let url = configFileURL() else {
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
    guard let url = configFileURL() else {
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

// Fetches ICY response headers to detect the station name.
// Cancels the transfer immediately after receiving headers to avoid buffering stream data.
class ICYHeaderDelegate: NSObject, URLSessionDataDelegate {
    var task: URLSessionDataTask?
    private let onName: (String?) -> Void

    init(_ onName: @escaping (String?) -> Void) {
        self.onName = onName
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        var name: String? = nil
        if let http = response as? HTTPURLResponse,
           let icyName = http.allHeaderFields["icy-name"] as? String, !icyName.isEmpty {
            name = icyName
        }
        DispatchQueue.main.async { self.onName(name) }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Cancellation after header receipt is expected; ignore
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
        adHocStation = nil
        adHocTitle = ""

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

        nowPlaying.onSongChanged = { songTitle in
            station.songTitle = songTitle
            updateNpInfo(station: station, songTitle: songTitle)
            notify(title: station.title, message: songTitle)
        }

        if play {
            playerPlay()
        }
    }

    private func playAdHoc(urlString: String, name: String) {
        guard let url = URL(string: urlString) else { return }

        player.currentItem?.remove(nowPlaying.output)

        let station = Station(title: name.isEmpty ? urlString : name, url: urlString)
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
        let alert = NSAlert()
        alert.messageText = "Play Radio Station"
        alert.informativeText = "Enter the stream URL:"
        alert.addButton(withTitle: "Play")
        alert.addButton(withTitle: "Cancel")

        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        urlField.placeholderString = "https://stream.example.com/radio"
        alert.accessoryView = urlField
        alert.window.initialFirstResponder = urlField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let urlString = urlField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !urlString.isEmpty else { return }
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
            // Reload config list without stopping playback
            if let updated = loadConfig() {
                config!.update(c: updated)
            }
        }
    }

    private func appendToConfig(title: String, url: String) {
        guard let fileUrl = configFileURL() else {
            NSLog("Configuration file not found")
            return
        }

        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let entry = "\n[[station]]\ntitle = \"\(escapedTitle)\"\nurl = \"\(url)\"\n"

        do {
            let handle = try FileHandle(forWritingTo: fileUrl)
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8)!)
            NSLog("Station '%@' added to config", title)
        } catch {
            NSLog("Failed to write to radio.conf: %@", error.localizedDescription)
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

        commandCenter.pauseCommand.addTarget { (event) -> MPRemoteCommandHandlerStatus in
            NSLog("remote pause")
            notify(title: config!.title, message: "Pause")
            playerPause()
            return .success
        }
        commandCenter.playCommand.addTarget { (event) -> MPRemoteCommandHandlerStatus in
            NSLog("remote play")
            if player.currentItem == nil && current < 0 {
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
                if player.currentItem == nil && current < 0 {
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
            NSLog("remote prev")
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
