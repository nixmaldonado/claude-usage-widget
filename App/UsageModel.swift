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

    /// How often to poll. The endpoint rate-limits aggressive clients; 2 min is gentle.
    static let interval: TimeInterval = 120

    private var timer: Timer?
    private var notBefore = Date.distantPast
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

    /// `userInitiated` skips the rate-limit backoff (menu "Refresh Now", widget tap).
    func refresh(userInitiated: Bool = false) {
        guard !isRefreshing else { return }
        if !userInitiated, Date() < notBefore { return }
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

        if case .rateLimited(let retryAfter) = error {
            notBefore = Date().addingTimeInterval(max(retryAfter ?? 0, 300))
        } else {
            notBefore = .distantPast
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
