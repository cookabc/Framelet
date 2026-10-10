import Foundation

struct RecordedClip: Identifiable, Equatable {
    let url: URL
    let date: Date
    var id: URL { url }
    var title: String {
        date.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_US")))
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
