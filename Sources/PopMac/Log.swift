import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "dev.krystof.popmac", category: "pop")
    static var verbose = ProcessInfo.processInfo.environment["POP_MAC_DEBUG"] != nil

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
        FileHandle.standardError.write(Data(("[debug] " + text + "\n").utf8))
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        if verbose { FileHandle.standardError.write(Data(("[info] " + message + "\n").utf8)) }
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        if verbose { FileHandle.standardError.write(Data(("[warn] " + message + "\n").utf8)) }
    }
}
