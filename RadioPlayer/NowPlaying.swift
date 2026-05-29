import AVKit
import Foundation
import UserNotifications

func requestNotifications() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .provisional]) { granted, error in
        if let error = error {
            NSLog("UN requestAuthorization %@", error.localizedDescription)
        } else {
            NSLog("UN requestAuthorization %@", granted ? "granted" : "denied")
        }
    }
}

func notify(title: String, message: String) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional else {
            NSLog("Notifications not authorized nor provisional")
            return
        }

        guard settings.alertSetting == .enabled else {
            NSLog("Alert notifications are disabled")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.categoryIdentifier = "com.github.raff.radio.RadioPlayer"

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        center.add(request)
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

                if let key = item.key as? String, key == "StreamTitle" {
                    update(title: value); return
                }
                if item.identifier == .commonIdentifierTitle {
                    update(title: value); return
                }
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
        var name: String?
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
