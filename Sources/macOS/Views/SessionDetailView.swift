import SwiftUI
import SwiftData

struct SessionDetailView: View {
    let session: ChatSession
    @Environment(\.modelContext) private var modelContext
    @State private var messageText = ""
    @State private var sendError: String?
    @Query(sort: \OutboxMessage.createdAt, order: .forward) private var outbox: [OutboxMessage]

    private var sortedMessages: [ChatMessage] {
        (session.messages ?? []).sorted { $0.order < $1.order }
    }

    private var displayMessages: [DisplayMessage] {
        let trimmedUserTexts = Set(sortedMessages.filter { $0.role == "user" }
            .map { normalize($0.content) })
        let maxOrder = sortedMessages.map(\.order).max() ?? -1

        var items = sortedMessages.map { message in
            DisplayMessage(
                id: String(describing: message.persistentModelID),
                role: message.role,
                content: message.content,
                order: message.order,
                status: nil,
                lastError: ""
            )
        }

        let outboxItems = outbox
            .filter { $0.sessionId == session.id }
            .filter { !trimmedUserTexts.contains(normalize($0.text)) }

        for (index, entry) in outboxItems.enumerated() {
            items.append(
                DisplayMessage(
                    id: "outbox-\(entry.id)",
                    role: "user",
                    content: entry.text,
                    order: maxOrder + 1 + index,
                    status: statusLabel(entry.status),
                    lastError: entry.lastError
                )
            )
        }

        return items.sorted { $0.order < $1.order }
    }

    var body: some View {
		ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(displayMessages) { message in
                    MessageCard(message: message)
                }
            }
            .padding()
        }
		.defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let sendError {
                    Text(sendError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    TextField("Send to Codex session…", text: $messageText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button("Send") {
                        sendCurrentMessage()
                    }
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle(session.title)
    }

    private func sendCurrentMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendError = nil
        let outbox = OutboxMessage(sessionId: session.id, text: trimmed, cwd: session.cwd)
        modelContext.insert(outbox)
        do {
            try modelContext.save()
        } catch {
            sendError = "Failed to queue message: \(error.localizedDescription)"
        }
        messageText = ""
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "pending":
            return "Queued"
        case "sending":
            return "Sending"
        case "sent":
            return "Sent"
        case "failed":
            return "Failed"
        default:
            return status.capitalized
        }
    }
}

private struct DisplayMessage: Identifiable {
    let id: String
    let role: String
    let content: String
    let order: Int
    let status: String?
    let lastError: String
}

private struct MessageCard: View {
    let message: DisplayMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.role.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = message.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status == "Failed" ? .red : .secondary)
                }
            }
            MarkdownText(message.content)
            if !message.lastError.isEmpty {
                Text(message.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
