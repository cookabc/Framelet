import Foundation

struct RecordedClip: Identifiable, Equatable {
    let url: URL
    let date: Date
    var id: URL { url }
    var title: String {
        date.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN")))
    }
    var day: String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN")))
    }
    var exportName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "录制-" + formatter.string(from: date)
    }
}
