import Foundation
import OSLog

public enum AppLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public struct AppLogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: AppLogLevel
    public let category: String
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: AppLogLevel,
        category: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

@MainActor
public final class AppLogStore: ObservableObject {
    @Published public private(set) var entries: [AppLogEntry] = []

    private let maximumEntryCount: Int
    private let subsystem: String

    public init(subsystem: String = "jp.example.ipphone", maximumEntryCount: Int = 500) {
        self.subsystem = subsystem
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    public func append(
        _ level: AppLogLevel,
        category: String,
        _ message: String
    ) {
        let safeMessage = Self.redactingSecrets(in: message)
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(safeMessage, privacy: .public)")
        case .info: logger.info("\(safeMessage, privacy: .public)")
        case .warning: logger.warning("\(safeMessage, privacy: .public)")
        case .error: logger.error("\(safeMessage, privacy: .public)")
        }
        entries.append(.init(level: level, category: category, message: safeMessage))
        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    public var exportedText: String {
        let formatter = ISO8601DateFormatter()
        return entries.map {
            "\(formatter.string(from: $0.timestamp)) [\($0.level.rawValue)] [\($0.category)] \($0.message)"
        }.joined(separator: "\n")
    }

    public static func redactingSecrets(in message: String) -> String {
        let patterns = [
            (#"(?i)(password\s*[=:]\s*)[^\s,;]+"#, "$1<redacted>"),
            (#"(?i)((?:api[_-]?key|token|secret)\s*[=:]\s*)[^\s,;]+"#, "$1<redacted>"),
            (#"(?i)(response\s*=\s*\")[^\"]+"#, "$1<redacted>"),
            (#"(?i)((?:proxy-)?authorization\s*:\s*)[^\r\n]+"#, "$1<redacted>"),
            (#"(?i)(sips?:[^\s:@]+:)[^\s@;>]+(@)"#, "$1<redacted>$2"),
        ]
        return patterns.reduce(message) { result, item in
            let (pattern, replacement) = item
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
            let range = NSRange(result.startIndex..., in: result)
            return regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement
            )
        }
    }
}
