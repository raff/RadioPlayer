import Foundation

class Station: Codable {
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

class Config: Codable {
    var title: String
    var station: [Station]

    func update(c: Config) {
        title = c.title
        station = c.station
    }
}
