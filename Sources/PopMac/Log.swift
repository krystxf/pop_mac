import Foundation
import os

/// Writes to the system log, and to stderr while `POP_MAC_DEBUG` is set.
///
/// `details` holds private data, such as window titles. The system log hides it,
/// unless private data logging is on. Stderr shows it, because only the person
/// who started Pop Mac sees stderr.
enum Log {
    private static let logger = Logger(subsystem: "dev.krystof.popmac", category: "pop")
    static var verbose = ProcessInfo.processInfo.environment["POP_MAC_DEBUG"] != nil

    static func debug(_ message: @autoclosure () -> String, private details: @autoclosure () -> String? = nil) {
        guard verbose else { return }
        write(.debug, "debug", message(), details())
    }

    static func info(_ message: String, private details: String? = nil) {
        write(.info, "info", message, details)
    }

    static func warn(_ message: String) {
        // Logger.warning writes at the error level.
        write(.error, "warn", message, nil)
    }

    private static func write(_ level: OSLogType, _ label: String, _ message: String, _ details: String?) {
        if let details {
            logger.log(level: level, "\(message, privacy: .public) \(details, privacy: .private)")
        } else {
            logger.log(level: level, "\(message, privacy: .public)")
        }
        if verbose {
            let text = details.map { message + " " + $0 } ?? message
            FileHandle.standardError.write(Data(("[\(label)] " + text + "\n").utf8))
        }
    }
}
