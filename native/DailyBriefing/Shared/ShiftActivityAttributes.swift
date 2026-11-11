import ActivityKit
import Foundation

struct ShiftActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startsAt: Date
        var endsAt: Date
    }
    var title: String
}
