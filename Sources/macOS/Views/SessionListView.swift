import SwiftUI
import SwiftData

struct SessionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ChatSession.sortDate, order: .reverse) private var sessions: [ChatSession]

    @StateObject private var monitor = CodexSessionMonitor()
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedSessions, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.sessions, id: \.persistentModelID) { session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title)
                                        .font(.headline)
                                    if !session.preview.isEmpty {
                                        Text(session.preview)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Text(session.sortDate, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Codex Sessions")
            .toolbar {
                if ProcessInfo.processInfo.environment["CODEX_DEBUG_LOG"] == "1" {
                    Text("\(sessions.count) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if ProcessInfo.processInfo.environment["CODEX_DEBUG_UI"] == "1" {
                    Button("Diagnostics") {
                        showDiagnostics = true
                    }
                }
                Button("Rescan") {
                    monitor.rescanNow()
                }
                Button("Force Reparse") {
                    monitor.forceRebuild()
                }
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            MonitorDiagnosticsView(stats: monitor.stats)
        }
        .onAppear {
            debugLog("list appear: sessions=\(sessions.count)")
            monitor.start(modelContext: modelContext)
        }
        .onChange(of: sessions.count) { _, newValue in
            debugLog("sessions count changed: \(newValue)")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                monitor.rescanNow()
            }
        }
    }
}

private struct SessionGroup: Identifiable {
    let id = UUID()
    let title: String
    let sessions: [ChatSession]
}

private extension SessionListView {
    var groupedSessions: [SessionGroup] {
        guard !sessions.isEmpty else { return [] }
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: todayStart)?.start ?? todayStart
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart) ?? thisWeekStart

        var buckets: [(String, [ChatSession])] = [
            ("Today", []),
            ("Yesterday", []),
            ("This Week", []),
            ("Last Week", []),
            ("Earlier", [])
        ]

        for session in sessions {
            let date = session.sortDate
            let index: Int
            if date >= todayStart {
                index = 0
            } else if date >= yesterdayStart {
                index = 1
            } else if date >= thisWeekStart {
                index = 2
            } else if date >= lastWeekStart {
                index = 3
            } else {
                index = 4
            }
            buckets[index].1.append(session)
        }

        return buckets.compactMap { title, items in
            guard !items.isEmpty else { return nil }
            return SessionGroup(title: title, sessions: items)
        }
    }

    func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["CODEX_DEBUG_LOG"] == "1" else { return }
        NSLog("[SessionListView] %@", message)
    }
}
