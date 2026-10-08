import Foundation

/// One rate-limit window as shown on claude.ai → Settings → Usage.
struct UsageLimit: Codable, Hashable, Identifiable {
    /// Stable key, e.g. "session", "weekly_all", "weekly_scoped:Fable".
    var id: String
    /// Display label, e.g. "Session", "This week", "Fable".
    var label: String
    /// Percent used, 0...100.
    var percent: Double
    var resetsAt: Date?
    /// "normal" | "warning" | "critical" when the API provides it.
    var severity: String?
    /// Length of the rolling window, used to draw the "even pace" marker.
    var windowSeconds: Double?
}

struct UsageSnapshot: Codable {
    enum Status: String, Codable {
        case ok          // last fetch succeeded
        case stale       // last fetch failed; limits are from an earlier success
        case signedOut   // no Claude Code login found / token rejected
        case error       // never fetched successfully
    }

    /// Time of the last successful fetch.
    var fetchedAt: Date?
    /// Time of the last attempt (successful or not).
    var checkedAt: Date
    /// "Max 5x", "Pro", … derived from the Claude Code credentials.
    var plan: String?
    var limits: [UsageLimit]
    var status: Status
    var message: String?
}

// MARK: - Display helpers (shared by the menu bar and the widget)

extension UsageLimit {
    /// Usage at `date`. A window whose reset time has passed is empty again,
    /// even if we haven't re-fetched yet.
    func percent(at date: Date) -> Double {
        if let resetsAt, resetsAt <= date { return 0 }
        return min(max(percent, 0), 100)
    }

    /// Fraction of the window that has elapsed at `date` (0...1), i.e. where an
    /// even burn rate would put you. Nil when the window length is unknown.
    func elapsedFraction(at date: Date) -> Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0, resetsAt > date else { return nil }
        let remaining = resetsAt.timeIntervalSince(date)
        return min(max(1 - remaining / windowSeconds, 0), 1)
    }

    var isCritical: Bool { severity == "critical" || percent >= 90 }
    var isWarning: Bool { severity == "warning" || percent >= 75 }

    /// Linear projection of when this window hits 100%, if that happens before it resets.
    func projectedRunOut(at date: Date) -> Date? {
        guard let resetsAt, let windowSeconds, let elapsed = elapsedFraction(at: date),
              elapsed >= 0.1, percent(at: date) > 0 else { return nil }
        let elapsedSeconds = elapsed * windowSeconds
        let ratePerSecond = percent(at: date) / elapsedSeconds
        let secondsToFull = (100 - percent(at: date)) / ratePerSecond
        let runOut = date.addingTimeInterval(secondsToFull)
        return runOut < resetsAt ? runOut : nil
    }

    /// "6:40 PM" when the reset is within a day, otherwise "Sat 10:00 AM".
    /// Follows the system 12/24-hour setting.
    func resetText(relativeTo date: Date) -> String? {
        guard let resetsAt else { return nil }
        if resetsAt <= date { return "reset" }
        if resetsAt.timeIntervalSince(date) < 20 * 3600 {
            return resetsAt.formatted(.dateTime.hour().minute())
        }
        return resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

extension UsageSnapshot {
    /// The all-models weekly window, used for the pace verdict.
    var weekly: UsageLimit? { limits.first { $0.id == "weekly_all" } }

    func isOld(at date: Date) -> Bool {
        guard let fetchedAt else { return true }
        return date.timeIntervalSince(fetchedAt) > 15 * 60
    }

    static let preview = UsageSnapshot(
        fetchedAt: Date(),
        checkedAt: Date(),
        plan: "Max 5x",
        limits: [
            UsageLimit(id: "session", label: "Session", percent: 7,
                       resetsAt: Date().addingTimeInterval(4.5 * 3600), severity: "normal", windowSeconds: 5 * 3600),
            UsageLimit(id: "weekly_all", label: "This week", percent: 72,
                       resetsAt: Date().addingTimeInterval(44 * 3600), severity: "normal", windowSeconds: 7 * 86400),
            UsageLimit(id: "weekly_scoped:Fable", label: "Fable", percent: 58,
                       resetsAt: Date().addingTimeInterval(44 * 3600), severity: "normal", windowSeconds: 7 * 86400),
        ],
        status: .ok,
        message: nil
    )
}

// MARK: - Shared file location

/// The menu-bar agent writes the snapshot here; the sandboxed widget reads it
/// through a read-only sandbox exception for this one folder.
enum SharedStore {
    static let folderName = "ClaudeUsageWidget"

    /// The real home folder. Inside the widget's sandbox, `NSHomeDirectory()`
    /// points at the container, so ask the password database instead.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var folder: URL {
        realHome.appendingPathComponent("Library/Application Support/\(folderName)", isDirectory: true)
    }

    static var fileURL: URL { folder.appendingPathComponent("usage.json") }

    static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    static func save(_ snapshot: UsageSnapshot) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
