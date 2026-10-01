import os

/// Unified-logging categories. Read with:
/// `log show --last 5m --predicate 'subsystem == "org.clickbait.ClickBait"'`
enum Log {
    private static let subsystem = "org.clickbait.ClickBait"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let ask = Logger(subsystem: subsystem, category: "ask")
}
