import Foundation

enum AppLogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case unknown = "UNKNOWN"

    var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        case .unknown: return 4
        }
    }
}

struct AppLogEntry {
    private static let timestampFormatter = ISO8601DateFormatter()

    let timestamp: String
    let level: AppLogLevel
    let message: String
    let isMalformed: Bool

    static func parse(_ line: String) -> AppLogEntry {
        let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3,
              !fields[0].isEmpty,
              timestampFormatter.date(from: String(fields[0])) != nil,
              let level = AppLogLevel(rawValue: String(fields[1])),
              level != .unknown
        else {
            return AppLogEntry(timestamp: "", level: .unknown, message: line, isMalformed: true)
        }
        return AppLogEntry(
            timestamp: String(fields[0]),
            level: level,
            message: String(fields[2]),
            isMalformed: false
        )
    }
}

final class AppLogger {
    static let shared = AppLogger()

    private let fileURL: URL
    private let formatter = ISO8601DateFormatter()
    var onChange: (() -> Void)?

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AwoX Mesh Controller", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("controller.log")
    }

    func write(_ message: String, level: AppLogLevel = .info) {
        guard level.priority >= AppSettings.minimumLogLevel.priority else { return }
        let sanitizedMessage = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let line = "\(formatter.string(from: Date()))|\(level.rawValue)|\(sanitizedMessage)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
        trimIfNeeded()
        onChange?()
    }

    func trimIfNeeded() {
        let limit = AppSettings.maximumLogSizeMB * 1_048_576
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > limit,
              let data = try? Data(contentsOf: fileURL)
        else { return }
        var retained = data.suffix(limit)
        if let newline = retained.firstIndex(of: 0x0a), newline < retained.endIndex {
            retained = retained[retained.index(after: newline)...]
        }
        try? Data(retained).write(to: fileURL, options: .atomic)
    }

    func contents() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func entries() -> [AppLogEntry] {
        contents()
            .split(whereSeparator: \Character.isNewline)
            .map { AppLogEntry.parse(String($0)) }
    }

    func clear() {
        try? Data().write(to: fileURL)
        onChange?()
    }
}