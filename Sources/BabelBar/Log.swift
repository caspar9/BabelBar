import os

/// Central loggers — view with Console.app or `log stream --predicate
/// 'subsystem == "com.babelbar.app"'`.
enum Log {
    static let app = Logger(subsystem: "com.babelbar.app", category: "app")
    static let audio = Logger(subsystem: "com.babelbar.app", category: "audio")
    static let stt = Logger(subsystem: "com.babelbar.app", category: "stt")
    static let session = Logger(subsystem: "com.babelbar.app", category: "session")
}
