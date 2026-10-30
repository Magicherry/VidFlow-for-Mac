import Foundation

/// A value guarded by a lock, for the little shared state that isn't owned by an actor.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
    public var current: Value {
        get { withLock { $0 } }
        set { withLock { $0 = newValue } }
    }
}

/// Where VidFlow keeps its data. ~/Library/Application Support/VidFlow by default; tests point it elsewhere.
public enum AppPaths {
    private static let override = Locked<URL?>(nil)

    public static var dataDir: URL {
        get {
            override.current ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VidFlow", isDirectory: true)
        }
        set { override.current = newValue }
    }

    public static var binDir: URL { dataDir.appendingPathComponent("bin", isDirectory: true) }
    public static var logsDir: URL { dataDir.appendingPathComponent("logs", isDirectory: true) }
    public static var updatesDir: URL { dataDir.appendingPathComponent("updates", isDirectory: true) }

    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Minimal daily-rolling file log under Application Support/VidFlow/logs. Keeps 7 days.
public enum Log {
    private static let state = Locked(false)

    public static func info(_ message: String) { write("INFO", message) }
    public static func warn(_ message: String) { write("WARN", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ raw: String) {
        // Links can carry access tokens and proxies passwords; none of that belongs in a file people send around.
        let message = Redact.text(raw)
        state.withLock { pruned in
            let fm = FileManager.default
            let dir = AppPaths.logsDir
            try? AppPaths.ensureDirectory(dir)
            if !pruned {
                pruned = true
                let cutoff = Date().addingTimeInterval(-7 * 86400)
                for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                    let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if file.lastPathComponent.hasPrefix("vidflow-"), let date, date < cutoff { try? fm.removeItem(at: file) }
                }
            }
            let now = Date()
            let file = dir.appendingPathComponent("vidflow-\(stamp(now, "yyyyMMdd")).log")
            let line = Data("\(stamp(now, "HH:mm:ss.SSS")) [\(level)] \(message)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file)
            }
        }
    }

    private static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }
}

/// Localized strings. Strings.tsv (key, English, Chinese) is the table shared with the Windows app; Strings.mac.tsv
/// adds the Mac's own strings and overrides the ones that talk about Windows.
public enum L {
    private static let table: [String: (en: String, zh: String)] = {
        var table: [String: (en: String, zh: String)] = [:]
        for name in ["Strings", "Strings.mac"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "tsv"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline).dropFirst() {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                if f.count >= 3 { table[String(f[0])] = (unescape(f[1]), chineseQuotes(unescape(f[2]))) }
            }
        }
        return table
    }()

    private static func unescape(_ s: Substring) -> String { s.replacingOccurrences(of: "\\n", with: "\n") }

    /// The shared table quotes Chinese with corner brackets; on the Mac it's the mainland's usual marks throughout.
    private static func chineseQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "「", with: "“").replacingOccurrences(of: "」", with: "”")
    }

    private static let chinese = Locked(Locale.preferredLanguages.first?.hasPrefix("zh") ?? false)

    /// Applies the user's language choice ("" = follow the system, "zh", "en").
    public static func apply(language: String) {
        chinese.current = switch language {
        case "zh": true
        case "en": false
        default: Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

    public static var isChinese: Bool { chinese.current }

    public static func get(_ key: String) -> String {
        guard let entry = table[key] else { return key }
        return isChinese ? entry.zh : entry.en
    }

    public static func format(_ key: String, _ args: Any...) -> String {
        var text = get(key)
        for (i, arg) in args.enumerated() { text = text.replacingOccurrences(of: "{\(i)}", with: "\(arg)") }
        return text
    }

    /// For tests.
    public static func has(_ key: String) -> Bool { table[key] != nil }
}

/// Small regular-expression helpers over NSRegularExpression.
enum RX {
    static func make(_ pattern: String, ignoreCase: Bool = false) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    static func firstGroups(_ regex: NSRegularExpression, in text: String) -> [String?]? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}

extension String {
    func containsIgnoringCase(_ part: String) -> Bool { range(of: part, options: .caseInsensitive) != nil }
}
