import AppKit
import Foundation
import TOMLDecoder

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

func appendToConfig(title: String, url: String) {
    guard let fileUrl = configFileURL() else {
        NSLog("Configuration file not found")
        return
    }

    let escapedTitle = title
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
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

    NSWorkspace.shared.open([url], withApplicationAt: appUrl, configuration: openConf) { app, _ in
        NSLog("edit started")
        if app != nil && doneHandler != nil {
            let listener = Observer { doneHandler!() }
            app!.addObserver(listener, forKeyPath: "isTerminated", context: nil)
            app!.removeObserver(listener, forKeyPath: "isTerminated")
        }
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

// Manages the most-recent-URLs list for the Play URL dialog.
class ConfigStore {
    static let shared = ConfigStore()

    private let key = "recent-urls"
    private let maxCount = 5

    private(set) var recentURLs: [String]

    private init() {
        recentURLs = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func addURL(_ url: String) {
        var urls = recentURLs.filter { $0 != url }
        urls.insert(url, at: 0)
        recentURLs = Array(urls.prefix(maxCount))
        UserDefaults.standard.set(recentURLs, forKey: key)
    }
}
