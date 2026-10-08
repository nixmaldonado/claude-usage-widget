import AppKit
import ServiceManagement
import SwiftUI
import WidgetKit

/// Polls the usage endpoint, writes the shared snapshot, and nudges the widget
/// when the numbers change.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled

    /// How often to poll. Usage moves slowly enough that 5 minutes is plenty,
    /// and it keeps the load on an unofficial endpoint low.
    static let interval: TimeInterval = 300
    /// Minimum spacing for manual refreshes (menu, widget click, claudeusage://).
    static let manualSpacing: TimeInterval = 30

    private var timer: Timer?
    /// Set from a 429: nothing fetches before this, manual refreshes included.
    private var rateLimitedUntil = Date.distantPast
    /// Set when the login is missing or rejected: automatic polls pause until
    /// then, but a manual refresh (after you run `claude`) still goes through.
    private var autoPausedUntil = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var lastSignature: String?
    private var lastWidgetReload = Date.distantPast

    init() {
        snapshot = SharedStore.load()
        lastSignature = snapshot.map(Self.signature)
    }

    func start() {
        registerLoginItemOnFirstRun()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// `userInitiated`: menu "Refresh Now" or a widget click. It skips the
    /// signed-out pause but never the rate-limit backoff, and is spaced 30 s apart
    /// so nothing (including a claudeusage:// link) can hammer the endpoint.
    func refresh(userInitiated: Bool = false) {
        let now = Date()
        guard !isRefreshing, now >= rateLimitedUntil else { return }
        if userInitiated {
            guard now.timeIntervalSince(lastAttempt) >= Self.manualSpacing else { return }
        } else if now < autoPausedUntil {
            return
        }
        lastAttempt = now
        isRefreshing = true
        let previous = snapshot
        Task {
            let (snap, error) = await Fetcher.run(previous: previous)
            apply(snap, error: error)
        }
    }

    private func apply(_ snap: UsageSnapshot, error: FetchError?) {
        isRefreshing = false
        snapshot = snap

        switch error {
        case .rateLimited(let retryAfter)?:
            rateLimitedUntil = Date().addingTimeInterval(min(max(retryAfter ?? 0, 600), 3600))
        case .unauthorized?, .notSignedIn?:
            autoPausedUntil = Date().addingTimeInterval(15 * 60)
        default:
            autoPausedUntil = .distantPast
        }

        do {
            try SharedStore.save(snap)
        } catch {
            logger.error("could not write snapshot: \(error.localizedDescription, privacy: .public)")
        }

        // Reload the widget when what it shows changes, plus a 30-minute heartbeat
        // so its "last updated" never looks older than it is. WidgetKit budgets
        // reloads, so don't push on every poll.
        let signature = Self.signature(snap)
        if signature != lastSignature || Date().timeIntervalSince(lastWidgetReload) > 30 * 60 {
            lastSignature = signature
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func signature(_ s: UsageSnapshot) -> String {
        s.status.rawValue + "|" + s.limits.map {
            "\($0.id)=\(Int($0.percent.rounded()))@\(Int($0.resetsAt?.timeIntervalSince1970 ?? 0))"
        }.joined(separator: ",")
    }

    // MARK: Login item

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("login item: \(error.localizedDescription, privacy: .public)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func registerLoginItemOnFirstRun() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setOpenAtLogin(true)
    }
}
