import SwiftUI

struct MonitorDiagnosticsView: View {
    let stats: MonitorStats

    var body: some View {
        Form {
            Section("Scanner") {
                LabeledContent("Total rescans", value: "\(stats.totalRescans)")
                LabeledContent("Last rescan", value: format(stats.lastRescanAt))
                LabeledContent("Last duration", value: formatDuration(stats.lastRescanDuration))
                LabeledContent("Last files", value: "\(stats.lastFileCount)")
                LabeledContent("Parsed", value: "\(stats.lastParsedCount)")
                LabeledContent("Skipped", value: "\(stats.lastSkippedCount)")
            }
            Section("Triggers") {
                LabeledContent("Monitor active", value: stats.monitorActive ? "Yes" : "No")
                LabeledContent("Last monitor event", value: format(stats.lastMonitorEventAt))
                LabeledContent("Polling enabled", value: stats.pollingEnabled ? "Yes" : "No")
                LabeledContent("Last poll", value: format(stats.lastPollAt))
            }
            Section("Outbox") {
                LabeledContent("Last outbox run", value: format(stats.lastOutboxRunAt))
                LabeledContent("Pending at run", value: "\(stats.lastOutboxPendingCount)")
            }
        }
        .padding()
        .frame(minWidth: 360, minHeight: 360)
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        guard value > 0 else { return "0s" }
        return String(format: "%.2fs", value)
    }
}
