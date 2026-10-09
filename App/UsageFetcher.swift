import Foundation
import os

let logger = Logger(subsystem: "com.nixmaldonado.ClaudeUsage", category: "fetch")

// MARK: - Claude Code credentials

struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date?
    let plan: String?
}

enum FetchError: LocalizedError {
    case notSignedIn
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Claude Code login found. Run `claude` in Terminal and sign in."
        case .unauthorized:
            return "Claude Code login expired. Run `claude` once to refresh it."
        case .rateLimited:
            return "Usage endpoint is rate limiting; backing off."
        case .http(let code):
            return "Usage endpoint returned HTTP \(code)."
        case .badResponse(let why):
            return "Unexpected response: \(why)"
        }
    }
}

/// Reads the OAuth login that Claude Code stores on this Mac. Read-only: this
/// never refreshes or rewrites the token, so it can't log Claude Code out.
enum CredentialStore {
    static let keychainService = "Claude Code-credentials"

    static func load() throws -> ClaudeCredentials {
        guard let raw = readKeychain() ?? readFile() else { throw FetchError.notSignedIn }
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw FetchError.notSignedIn }

        var expiresAt: Date?
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            expiresAt = Date(timeIntervalSince1970: ms / 1000)
        }
        let plan = planLabel(subscription: oauth["subscriptionType"] as? String,
                             tier: oauth["rateLimitTier"] as? String)
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt, plan: plan)
    }

    /// Uses /usr/bin/security, the same tool Claude Code uses to write the
    /// item, so macOS doesn't ask for Keychain access each time the token rotates.
    private static func readKeychain() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Older Claude Code builds (and Linux) keep the same JSON in a file.
    private static func readFile() -> String? {
        let url = SharedStore.realHome.appendingPathComponent(".claude/.credentials.json")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// "max" + "default_claude_max_5x" → "Max 5x"; "pro" → "Pro".
    static func planLabel(subscription: String?, tier: String?) -> String? {
        guard let subscription, !subscription.isEmpty else { return nil }
        var label = subscription.prefix(1).uppercased() + subscription.dropFirst()
        if let tier, let range = tier.range(of: #"\d+x$"#, options: .regularExpression) {
            label += " \(tier[range])"
        }
        return label
    }
}

// MARK: - Usage endpoint

/// GET https://api.anthropic.com/api/oauth/usage — the endpoint behind
/// Claude Code's /usage. Undocumented, so the parser below is deliberately lenient.
enum UsageAPI {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Identifies this app honestly instead of posing as Claude Code.
    static let userAgent = "ClaudeUsageWidget/\(AppVersion.short) (+https://github.com/nixmaldonado/claude-usage-widget)"

    /// Never follow redirects, so the bearer token can't be re-sent to another host.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func fetch(token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse("not HTTP") }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw FetchError.unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
            throw FetchError.rateLimited(retryAfter: retry)
        default:
            // Status only: response bodies never reach logs, disk or the widget.
            throw FetchError.http(http.statusCode)
        }
    }
}

enum UsageParser {
    private static let fiveHours: Double = 5 * 3600
    private static let sevenDays: Double = 7 * 86400

    static func parse(_ data: Data) throws -> [UsageLimit] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badResponse("not a JSON object")
        }

        var limits: [UsageLimit] = []

        // Current shape: a `limits` array. Model-scoped caps (Fable) only exist here.
        if let entries = root["limits"] as? [[String: Any]] {
            for entry in entries {
                guard let kind = entry["kind"] as? String,
                      let percent = number(entry["percent"]) ?? number(entry["utilization"])
                else { continue }

                let scope = entry["scope"] as? [String: Any]
                let model = name(scope?["model"])
                let surface = name(scope?["surface"])

                var id = kind
                let label: String
                let window: Double?
                switch kind {
                case "session":
                    label = "Session"; window = fiveHours
                case "weekly_all":
                    label = "This week"; window = sevenDays
                case "weekly_scoped":
                    let parts = [model, surface].compactMap { $0 }
                    label = parts.isEmpty ? "Weekly (scoped)" : parts.joined(separator: " · ")
                    window = sevenDays
                default:
                    label = kind.replacingOccurrences(of: "_", with: " ").capitalized
                    window = kind.hasPrefix("weekly") ? sevenDays : nil
                }
                if let model { id += ":\(model)" }
                if let surface { id += "@\(surface)" }

                limits.append(UsageLimit(id: id, label: label, percent: percent,
                                         resetsAt: date(entry["resets_at"]),
                                         severity: entry["severity"] as? String,
                                         windowSeconds: window))
            }
        }

        // Older shape: named windows only.
        if limits.isEmpty {
            let named: [(key: String, id: String, label: String, window: Double)] = [
                ("five_hour", "session", "Session", fiveHours),
                ("seven_day", "weekly_all", "This week", sevenDays),
                ("seven_day_opus", "weekly_scoped:Opus", "Opus", sevenDays),
                ("seven_day_sonnet", "weekly_scoped:Sonnet", "Sonnet", sevenDays),
            ]
            for item in named {
                guard let window = root[item.key] as? [String: Any],
                      let utilization = number(window["utilization"]) else { continue }
                limits.append(UsageLimit(id: item.id, label: item.label, percent: utilization,
                                         resetsAt: date(window["resets_at"]), severity: nil,
                                         windowSeconds: item.window))
            }
        }

        if limits.isEmpty {
            throw FetchError.badResponse("no usage windows in response")
        }

        // Same order as claude.ai: session, weekly, then model-scoped.
        func rank(_ l: UsageLimit) -> Int {
            if l.id == "session" { return 0 }
            if l.id == "weekly_all" { return 1 }
            return 2
        }
        return limits.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private static func number(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap { Double($0) }
    }

    /// Scope parts arrive as `{"display_name": …}`, a bare string, or null.
    private static func name(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let d = any as? [String: Any] {
            if let s = d["display_name"] as? String, !s.isEmpty { return s }
            if let s = d["name"] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// Accepts "…Z", "…+00:00", fractional seconds of any length, and
    /// timestamps without a zone (treated as UTC).
    static func date(_ any: Any?) -> Date? {
        guard var s = any as? String, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        if s.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) == nil { s += "Z" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - One fetch cycle

enum Fetcher {
    /// Fetches fresh usage and merges it with the previous snapshot so a failed
    /// fetch keeps showing the last known numbers.
    static func run(previous: UsageSnapshot?) async -> (UsageSnapshot, FetchError?) {
        let now = Date()
        do {
            let creds = try CredentialStore.load()
            let data = try await UsageAPI.fetch(token: creds.accessToken)
            let limits = try UsageParser.parse(data)
            logger.info("fetched \(limits.count) limits")
            return (UsageSnapshot(fetchedAt: now, checkedAt: now, plan: creds.plan,
                                  limits: limits, status: .ok, message: nil), nil)
        } catch {
            let fetchError = (error as? FetchError) ?? .badResponse(error.localizedDescription)
            logger.error("fetch failed: \(fetchError.localizedDescription, privacy: .public)")
            var snap = previous ?? UsageSnapshot(fetchedAt: nil, checkedAt: now, plan: nil,
                                                 limits: [], status: .error, message: nil)
            snap.checkedAt = now
            snap.message = fetchError.localizedDescription
            switch fetchError {
            case .notSignedIn, .unauthorized:
                snap.status = .signedOut
            default:
                snap.status = snap.fetchedAt == nil ? .error : .stale
            }
            return (snap, fetchError)
        }
    }
}
