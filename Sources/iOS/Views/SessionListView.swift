import SwiftUI
import SwiftData

struct SessionListView: View {
    @Query(sort: \ChatSession.sortDate, order: .reverse) private var sessions: [ChatSession]

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
}
