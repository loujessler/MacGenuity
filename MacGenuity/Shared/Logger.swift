//
//  Logger.swift
//  MacGenuity
//
//  Structured logger with levels, a rotating file sink, and an in-memory
//  ring buffer surfaced to the diagnostics window.
//

import Foundation
import os.log
import Combine

enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .default
        case .error:   return .error
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum LogChannel: String {
    case app
    case hid
    case audio
    case settings
    case ui
    case battery
    case lighting
}

struct LogEntry: Identifiable, Equatable {
    let id: UInt64
    let date: Date
    let level: LogLevel
    let channel: LogChannel
    let message: String

    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool { lhs.id == rhs.id }
}

protocol LoggerType {
    func log(_ level: LogLevel, _ channel: LogChannel, _ message: @autoclosure () -> String)
}

extension LoggerType {
    func debug(_ channel: LogChannel = .app, _ message: @autoclosure () -> String)   { log(.debug,   channel, message()) }
    func info(_ channel: LogChannel = .app, _ message: @autoclosure () -> String)    { log(.info,    channel, message()) }
    func warning(_ channel: LogChannel = .app, _ message: @autoclosure () -> String) { log(.warning, channel, message()) }
    func error(_ channel: LogChannel = .app, _ message: @autoclosure () -> String)   { log(.error,   channel, message()) }
}

final class FileLogger: LoggerType, ObservableObject {
    static let shared = FileLogger()

    let fileURL: URL
    var minimumLevel: LogLevel = .info

    /// Live tail observed by the diagnostics window. Always replaces the
    /// entire array (capped at `tailCapacity`) so SwiftUI gets a single
    /// `objectWillChange` per write.
    @Published private(set) var tail: [LogEntry] = []

    private let queue = DispatchQueue(label: "io.github.loujessler.macgenuity.logger", qos: .utility)
    private let osLog = OSLog(subsystem: "io.github.loujessler.macgenuity", category: "app")
    private let maxBytes: UInt64 = 5 * 1024 * 1024
    private let pruneToBytes: Int = 4 * 1024 * 1024
    private let tailCapacity = 500
    private var nextID: UInt64 = 0

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        fileURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MacGenuity", isDirectory: true)
            .appendingPathComponent("MacGenuity.log")
    }

    func log(_ level: LogLevel, _ channel: LogChannel, _ message: @autoclosure () -> String) {
        guard level >= minimumLevel else { return }
        let resolved = message()
        let timestamp = Date()
        let line = "\(formatter.string(from: timestamp)) [\(level.label)] [\(channel.rawValue)] \(resolved)"
        os_log("%{public}@", log: osLog, type: level.osLogType, line)

        let entry = LogEntry(id: assignID(), date: timestamp, level: level, channel: channel, message: resolved)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var tail = self.tail
            tail.append(entry)
            if tail.count > self.tailCapacity {
                tail.removeFirst(tail.count - self.tailCapacity)
            }
            self.tail = tail
        }

        queue.async { [weak self] in
            self?.append(line + "\n")
        }
    }

    func clearTail() {
        DispatchQueue.main.async { [weak self] in self?.tail = [] }
    }

    private func assignID() -> UInt64 {
        // Per-call ID, reasonably unique for SwiftUI.
        let id = nextID
        nextID &+= 1
        return id
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try rotateIfNeeded()

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL)
            }
        } catch {
            // Logging must never crash the app.
        }
    }

    private func rotateIfNeeded() throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxBytes else { return }
        let data = try Data(contentsOf: fileURL)
        let keep = min(pruneToBytes, data.count)
        let tail = data.suffix(keep)
        try Data(tail).write(to: fileURL, options: .atomic)
    }
}

extension Data {
    func hexDump(limit: Int = 96) -> String {
        let bytes = Array(self.prefix(limit))
        let body = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return count > limit ? "\(body) ... (\(count) bytes)" : "\(body) (\(count) bytes)"
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Parse a hex string of any common shape into Data:
    /// "DE AD BE EF", "DEADBEEF", "0xDE 0xAD". Returns nil on garbage.
    static func parseHex(_ string: String) -> Data? {
        let cleaned = string
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .components(separatedBy: ",").joined()
        guard cleaned.count.isMultiple(of: 2), !cleaned.isEmpty else { return nil }

        var result = Data()
        result.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}
