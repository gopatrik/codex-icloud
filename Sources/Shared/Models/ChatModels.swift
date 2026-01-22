import Foundation
import SwiftData

@Model
final class ChatSession {
    var id: String = ""
    var sourcePath: String = ""
    var sourceModTime: Date = Foundation.Date.distantPast
    var sourceFileSize: Int64 = 0
    var lastParsedOffset: Int64 = 0
    var sortDate: Date = Foundation.Date.distantPast
    var title: String = ""
    var cwd: String = ""
    var preview: String = ""

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage]?

    init(
        id: String = UUID().uuidString,
        sourcePath: String = "",
        sourceModTime: Date = Foundation.Date.distantPast,
        sourceFileSize: Int64 = 0,
        lastParsedOffset: Int64 = 0,
        sortDate: Date = Foundation.Date.distantPast,
        title: String = "",
        cwd: String = "",
        preview: String = "",
        messages: [ChatMessage]? = nil
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.sourceModTime = sourceModTime
        self.sourceFileSize = sourceFileSize
        self.lastParsedOffset = lastParsedOffset
        self.sortDate = sortDate
        self.title = title
        self.cwd = cwd
        self.preview = preview
        self.messages = messages
    }
}

@Model
final class ChatMessage {
    var role: String = ""
    var content: String = ""
    var order: Int = 0

    @Relationship var session: ChatSession?

    init(
        role: String = "",
        content: String = "",
        order: Int = 0,
        session: ChatSession? = nil
    ) {
        self.role = role
        self.content = content
        self.order = order
        self.session = session
    }
}

@Model
final class OutboxMessage {
    var id: String = ""
    var sessionId: String = ""
    var text: String = ""
    var createdAt: Date = Foundation.Date.distantPast
    var status: String = "pending"
    var lastError: String = ""
    var cwd: String = ""

    init(
        id: String = UUID().uuidString,
        sessionId: String = "",
        text: String = "",
        createdAt: Date = Foundation.Date.now,
        status: String = "pending",
        lastError: String = "",
        cwd: String = ""
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.createdAt = createdAt
        self.status = status
        self.lastError = lastError
        self.cwd = cwd
    }
}
