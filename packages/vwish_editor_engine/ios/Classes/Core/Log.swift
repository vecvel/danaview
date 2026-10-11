// OWNER: ENG-07 (frozen with the glue by ENG-06)
//
// Engine logging (ARCH §19): `os_log` through `os.Logger` only. Messages never carry media paths,
// file URIs or user content: every message goes through `Log.scrub`, the native twin of
// error_mapper.dart's `scrubPaths`, before it reaches the system log. Callers pass codes, ids and
// counts, never file names.

import Foundation
import os

/// The engine's logger. Thread-safe.
enum Log {
    /// Subsystem shown in Console.app.
    static let subsystem = "com.vecvel.vwish.editor.engine"

    /// Log categories (one per engine area).
    enum Category: String, CaseIterable {
        case glue, engine, events, preview, jobs, export, media, platform, recorder
    }

    /// Severity of a log line.
    enum Level: String {
        case debug, info, error, fault
    }

    /// Test hook: receives every line after scrubbing (RunnerTests/Glue asserts that no path leaks).
    /// Set and cleared on the main thread by tests only.
    static var testSink: ((Level, Category, String) -> Void)?

    private static let loggers: [Category: Logger] = {
        var map: [Category: Logger] = [:]
        for category in Category.allCases {
            map[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return map
    }()

    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        #if DEBUG
        write(.debug, category, message())
        #endif
    }

    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        write(.info, category, message())
    }

    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        write(.error, category, message())
    }

    static func fault(_ category: Category, _ message: @autoclosure () -> String) {
        write(.fault, category, message())
    }

    private static func write(_ level: Level, _ category: Category, _ raw: String) {
        let text = scrub(raw)
        let logger = loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        case .fault: logger.fault("\(text, privacy: .public)")
        }
        testSink?(level, category, text)
    }

    // Same pattern as error_mapper.dart `_pathLike`: file/content URIs, and absolute paths with at
    // least one directory separator that do not follow a word character or a dot.
    private static let pathPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(file|content)://\S+|(?<![\w.])/(?:[^\s/'"]+/)+[^\s'"]*"#)

    /// Replaces anything that looks like a file path or a file/content URI with `<path>`.
    static func scrub(_ text: String) -> String {
        guard let regex = pathPattern, !text.isEmpty else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "<path>")
    }
}
