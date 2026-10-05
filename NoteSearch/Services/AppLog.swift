import Foundation
import OSLog

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "ru.vincento.NoteSearch"

    static let index = Logger(subsystem: subsystem, category: "index")
    static let search = Logger(subsystem: subsystem, category: "search")
    static let watch = Logger(subsystem: subsystem, category: "watch")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let system = Logger(subsystem: subsystem, category: "system")
}
