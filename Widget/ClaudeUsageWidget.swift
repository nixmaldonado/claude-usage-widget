import SwiftUI
import WidgetKit

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let stored = SharedStore.load()
        completion(UsageEntry(date: Date(), snapshot: context.isPreview ? (stored ?? .preview) : stored))
    }

    /// The menu-bar app pushes a reload whenever the numbers change. These
    /// entries only move time-based bits forward: the pace marker, and a
    /// window dropping to 0% once its reset time passes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = SharedStore.load()
        let now = Date()
        let horizon = now.addingTimeInterval(3 * 3600)

        var dates = stride(from: 0.0, to: 3 * 3600, by: 15 * 60).map { now.addingTimeInterval($0) }
        for limit in snapshot?.limits ?? [] {
            if let reset = limit.resetsAt, reset > now, reset < horizon {
                dates.append(reset.addingTimeInterval(1))
            }
        }
        let entries = dates.sorted().map { UsageEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

// MARK: - Widget

@main
struct ClaudeUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeUsageWidget()
    }
}

struct ClaudeUsageWidget: Widget {
    let kind = "ClaudeUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "claudeusage://refresh"))
        }
        .configurationDisplayName("Claude Usage")
        .description("Session, weekly and Fable limits with reset times.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Style

enum Palette {
    /// Claude's terracotta, used the way the Calendar widget uses red for the weekday.
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let critical = Color(red: 0.898, green: 0.282, blue: 0.302)

    static func fill(for limit: UsageLimit) -> Color {
        limit.isCritical ? critical : claude
    }
}

// MARK: - Views

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.limits.isEmpty {
            switch family {
            case .systemMedium:
                MediumView(snapshot: snapshot, now: entry.date)
            default:
                SmallView(snapshot: snapshot, now: entry.date)
            }
        } else {
            EmptyStateView(snapshot: entry.snapshot)
        }
    }
}

struct Header: View {
    let title: String
    let plan: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.claude)
                .widgetAccentable()
            Spacer(minLength: 4)
            if let plan {
                Text(plan)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Usage bar with a tick where an even burn rate would be right now.
struct UsageBar: View {
    let limit: UsageLimit
    let now: Date
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let used = CGFloat(limit.percent(at: now) / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Palette.fill(for: limit))
                    .frame(width: max(used > 0 ? height : 0, geo.size.width * used))
                    .widgetAccentable()
                if let pace = limit.elapsedFraction(at: now), pace > 0.02, pace < 0.98 {
                    Rectangle()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: geo.size.width * CGFloat(pace) - 0.75)
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height + 4)
    }
}

struct SmallView: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "CLAUDE", plan: snapshot.plan)
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(snapshot.limits.prefix(3)) { limit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(limit.label)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Int(limit.percent(at: now).rounded()))%")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(limit.isCritical ? Palette.critical : .primary)
                        }
                        UsageBar(limit: limit, now: now, height: 5)
                        if let reset = limit.resetText(relativeTo: now) {
                            Text(reset)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if let note = StaleNote(snapshot: snapshot, now: now).text {
                Spacer(minLength: 4)
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }
}

struct MediumView: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "CLAUDE USAGE", plan: snapshot.plan)
            Spacer(minLength: 8)
            VStack(spacing: snapshot.limits.count > 3 ? 7 : 11) {
                ForEach(snapshot.limits.prefix(4)) { limit in
                    HStack(spacing: 10) {
                        Text(limit.label)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .frame(width: 74, alignment: .leading)
                        UsageBar(limit: limit, now: now)
                        Text("\(Int(limit.percent(at: now).rounded()))%")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(limit.isCritical ? Palette.critical : .primary)
                            .frame(width: 38, alignment: .trailing)
                        Text(limit.resetText(relativeTo: now) ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 78, alignment: .trailing)
                    }
                }
            }
            Spacer(minLength: 8)
            Footer(snapshot: snapshot, now: now)
        }
    }
}

struct Footer: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        if let note = StaleNote(snapshot: snapshot, now: now).text {
            Label(note, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if let weekly = snapshot.weekly {
            if let runOut = weekly.projectedRunOut(at: now) {
                Text("At this pace the week runs out \(runOut.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.claude)
                    .lineLimit(1)
            } else if let reset = weekly.resetsAt, reset > now {
                Text("On track for the \(reset.formatted(.dateTime.weekday(.wide))) reset")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Explains why the numbers might be out of date, or nil when they're fresh.
struct StaleNote {
    let snapshot: UsageSnapshot
    let now: Date

    var text: String? {
        let updated = snapshot.fetchedAt.map { "Updated \($0.formatted(.dateTime.hour().minute()))" } ?? "Not updated"
        switch snapshot.status {
        case .signedOut:
            return "\(updated) · run `claude` to sign in"
        case .stale, .error:
            return "\(updated) · couldn't refresh"
        case .ok:
            guard let fetchedAt = snapshot.fetchedAt, now.timeIntervalSince(fetchedAt) > 45 * 60 else { return nil }
            return "\(updated) · is Claude Usage running?"
        }
    }
}

struct EmptyStateView: View {
    let snapshot: UsageSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(title: "CLAUDE", plan: nil)
            Spacer()
            Text(snapshot?.message ?? "Open the Claude Usage app to start tracking.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview(as: .systemMedium) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: .preview)
}

#Preview(as: .systemSmall) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: .preview)
}
