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
        //throw Error.fileNotFound(name: "radio.conf")
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
        //throw Error.fileNotFound(name: "radio.conf")
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

@available(macOS 13.0, *)
@main
struct RadioPlayerApp: App {
    private var npCenter : MPNowPlayingInfoCenter?
    private var player : AVPlayer
    private var config : Config?
    
    @AppStorage("current-station") var current : Int = -1
    @State private var ext = ""
    
    init() {
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
        //icon = "play.fill"
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }
    
    private func playerPause() {
        self.player.pause()
        ext = ""
        //icon = "play"
        MPNowPlayingInfoCenter.default().playbackState = .paused
    }
    
    private func playerSelect(index: Int, play: Bool) {
        if index < 0 || index > config!.station.count || config?.station[index].url == "" {
            player.replaceCurrentItem(with: nil)
            playerPause()
            current = -1
            return
        }
        
        current = index
                
        let station = config?.station[index]
        updateNpInfo(station: station!)
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(string: station!.url)!))
        
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
    
    private func updateNpInfo(station: Station) {
        npCenter?.nowPlayingInfo = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
            MPMediaItemPropertyTitle: station.title,
            MPMediaItemPropertyPodcastTitle: station.title,
            MPNowPlayingInfoPropertyAssetURL: URL(string: station.url) as Any,
            //MPMediaItemPropertyArtist: self.artist,
            //MPMediaItemPropertyPlaybackDuration: self.duration,
            //MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime(),
        ]
    }
    
    var body: some Scene {
        MenuBarExtra(String("Radio"), systemImage: "radio\(ext)") {
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
                        Text(station.title)
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
