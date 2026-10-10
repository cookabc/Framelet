import Foundation

struct RecordedClip: Identifiable, Equatable {
    let url: URL
    let date: Date
    var id: URL { url }

    /// Keeps the AM/PM marker. Dropping it turned a 15:37 recording into "03:37", which reads as
    /// the middle of the night — and as a duration next to the player's own mm:ss readout.
    var title: String {
        date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "en_US")))
    }

    var day: String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "en_US")))
    }
    var exportName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Framelet-" + formatter.string(from: date)
    }
}
