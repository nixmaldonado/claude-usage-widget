import AppKit
import ServiceManagement
import SwiftUI
import WidgetKit

/// Entry point. `--once` fetches, saves, prints the snapshot and exits (handy
/// for checking the setup from Terminal); `--raw` prints the raw API response;
/// `--parse <file>` runs the parser on a saved response (used by the tests).
@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--version") {
            print(AppVersion.description)
            exit(0)
        } else if args.contains("--unregister-login-item") {
            // Used by uninstall.sh so no stale background item is left behind.
            try? SMAppService.mainApp.unregister()
            exit(0)
        } else if let i = args.firstIndex(of: "--parse"), i + 1 < args.count {
            exit(CommandLineTools.parseFile(args[i + 1]))
        } else if args.contains("--raw") {
            exit(CommandLineTools.printRaw())
        } else if args.contains("--once") {
            exit(CommandLineTools.fetchOnce())
        } else {
            ClaudeUsageApp.main()
        }
    }
}

/// "Claude Usage 0.1.0 (build 7, abc1234)". The build number and commit come
/// from the CI run that produced the app, so two builds are easy to tell apart.
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var description: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["ClaudeUsageCommit"] as? String ?? "dev"
        return "Claude Usage \(short) (build \(build), \(commit))"
    }
}

enum CommandLineTools {
    /// Runs an async job on a background task and waits for it.
    private static func blocking(_ job: @escaping @Sendable () async -> Int32) -> Int32 {
        final class Box: @unchecked Sendable { var value: Int32 = 1 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await job()
            done.signal()
        }
        done.wait()
        return box.value
    }

    static func fetchOnce() -> Int32 {
        blocking {
            let (snapshot, error) = await Fetcher.run(previous: SharedStore.load())
            if error == nil {
                try? SharedStore.save(snapshot)
                WidgetCenter.shared.reloadAllTimelines()
            }
            if let data = try? SharedStore.encoder.encode(snapshot) {
                print(String(decoding: data, as: UTF8.self))
            }
            if let error {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                return 1
            }
            return 0
        }
    }

    /// One line per limit: id|label|percent|resetsAt|severity
    static func parseFile(_ path: String) -> Int32 {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let iso = ISO8601DateFormatter()
            for limit in try UsageParser.parse(data) {
                let fields = [
                    limit.id,
                    limit.label,
                    String(format: "%g", limit.percent),
                    limit.resetsAt.map { iso.string(from: $0) } ?? "-",
                    limit.severity ?? "-",
                ]
                print(fields.joined(separator: "|"))
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func printRaw() -> Int32 {
        blocking {
            do {
                let creds = try CredentialStore.load()
                let data = try await UsageAPI.fetch(token: creds.accessToken)
                print(String(decoding: data, as: UTF8.self))
                return 0
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        }
    }
}

struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuContent(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// Opening the app again (Finder, Spotlight, or clicking the widget)
    /// refreshes right away and brings back a hidden menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
        model.refresh(userInitiated: true)
        return false
    }

    /// claudeusage://refresh — sent when the widget is clicked. Any app or web
    /// page can open this URL, so it only ever triggers a throttled refresh.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "claudeusage" && $0.host == "refresh" }) else { return }
        model.refresh(userInitiated: true)
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        let top = model.snapshot?.limits.map { $0.percent(at: Date()) }.max()
        HStack(spacing: 3) {
            Image(systemName: "gauge.medium")
            if let top {
                Text("\(Int(top.rounded()))%")
            }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: UsageModel
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        let now = Date()
        if let snap = model.snapshot, !snap.limits.isEmpty {
            ForEach(snap.limits) { limit in
                Text(line(for: limit, now: now))
            }
            if let plan = snap.plan {
                Text("Plan: \(plan)")
            }
            Divider()
        }
        Text(statusLine(now: now))

        Button("Refresh Now") { model.refresh(userInitiated: true) }
            .keyboardShortcut("r")
        Button("Open Usage Page…") {
            NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
        }
        Divider()
        Toggle("Open at Login", isOn: Binding(
            get: { model.openAtLogin },
            set: { model.setOpenAtLogin($0) }
        ))
        Button("Hide Menu Bar Icon") { showMenuBarIcon = false }
        Divider()
        Text(AppVersion.description)
        Button("Quit Claude Usage") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func line(for limit: UsageLimit, now: Date) -> String {
        var text = "\(limit.label): \(Int(limit.percent(at: now).rounded()))%"
        if let reset = limit.resetText(relativeTo: now) {
            text += reset == "reset" ? " · reset" : " · resets \(reset)"
        }
        return text
    }

    private func statusLine(now: Date) -> String {
        if model.isRefreshing { return "Refreshing…" }
        guard let snap = model.snapshot else { return "Not fetched yet" }
        switch snap.status {
        case .ok:
            let time = (snap.fetchedAt ?? now).formatted(.dateTime.hour().minute())
            return "Updated \(time)"
        default:
            return snap.message ?? "Couldn't update"
        }
    }
}
