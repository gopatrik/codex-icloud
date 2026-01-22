import Foundation
import SwiftData

@MainActor
final class CodexSessionMonitor: ObservableObject {
    private let rootURL: URL
    private let importer = CodexSessionImporter()
    private var directoryMonitor: DirectoryMonitor?
    private var debounceTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?
    private var isScanning = false
    private var hasStarted = false
    private var lastRescanAt: Date?
    private weak var modelContext: ModelContext?
    private let minRescanInterval: TimeInterval = 3.0
    @Published private(set) var stats = MonitorStats()

    init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)) {
        self.rootURL = rootURL
    }

    deinit {
        directoryMonitor?.stop()
        debounceTask?.cancel()
        pollingTask?.cancel()
        outboxTask?.cancel()
    }

    func start(modelContext: ModelContext) {
        if hasStarted { return }
        hasStarted = true
        self.modelContext = modelContext
        log("start: modelContext ready")
        let monitoringActive = startMonitoring()
        stats.monitorActive = monitoringActive
        if shouldEnablePolling(monitoringActive: monitoringActive) {
            startPolling()
            stats.pollingEnabled = true
        }
        startOutboxProcessing()
        rescanNow()
    }

    func rescanNow() {
        rescanNow(force: false)
    }

    func forceRebuild() {
        rescanNow(force: true)
    }

    private func rescanNow(force: Bool) {
        guard !isScanning, let modelContext else { return }
        if !force, let lastRescanAt, Date().timeIntervalSince(lastRescanAt) < minRescanInterval {
            log("rescan: skipped (cooldown)")
            return
        }
        lastRescanAt = Date()
        isScanning = true
        let scanStart = Date()
        Self.statusLog("rescan: starting (force=\(force))")
        stats.lastRescanAt = scanStart
        stats.totalRescans += 1

        let existingSessions = (try? modelContext.fetch(FetchDescriptor<ChatSession>())) ?? []
        log("rescan: existing \(existingSessions.count) sessions")
        var deduped: [String: ChatSession] = [:]
        var duplicates: [ChatSession] = []

        for session in existingSessions {
            if let existing = deduped[session.sourcePath] {
                if session.sourceModTime >= existing.sourceModTime {
                    duplicates.append(existing)
                    deduped[session.sourcePath] = session
                } else {
                    duplicates.append(session)
                }
            } else {
                deduped[session.sourcePath] = session
            }
        }

        if !duplicates.isEmpty {
            log("rescan: removing \(duplicates.count) duplicate sessions")
            for session in duplicates {
                modelContext.delete(session)
            }
            try? modelContext.save()
        }

        let existingMap: [String: (Date, Bool, Int64, Int64)]
        if force {
            log("rescan: force rebuild")
            for session in deduped.values {
                modelContext.delete(session)
            }
            try? modelContext.save()
            existingMap = [:]
        } else {
            existingMap = Dictionary(uniqueKeysWithValues: deduped.values.map { session in
                let needsRefresh = session.preview.isEmpty
                return (session.sourcePath, (session.sourceModTime, needsRefresh, session.lastParsedOffset, session.sourceFileSize))
            })
        }

        let rootURL = rootURL
        Task.detached(priority: .utility) { [importer] in
            let fileManager = FileManager.default
            let files = importer.discoverSessionFiles(rootURL: rootURL)
            var parsedSessions: [ParsedSession] = []
            var skipped = 0
            let fileCount = files.count
            var processed = 0
            var lastProgressLog = Date.distantPast
            let progressInterval: TimeInterval = 1.0
            let maxBytesPerRescan = Self.scanBudgetBytes()
            var remainingBytes = maxBytesPerRescan
            var hitBudget = false

            if maxBytesPerRescan > 0 {
                let mb = Double(maxBytesPerRescan) / (1024.0 * 1024.0)
                Self.statusLog("rescan: found \(fileCount) files (budget \(String(format: "%.1f", mb)) MB)")
            } else {
                Self.statusLog("rescan: found \(fileCount) files (budget unlimited)")
            }

            for url in files {
                guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { continue }
                guard let modTime = attrs[.modificationDate] as? Date else { continue }
                let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

                let existingOffset = existingMap[url.path]?.2 ?? 0
                let existingSize = existingMap[url.path]?.3 ?? 0
                if let existing = existingMap[url.path], !existing.1 {
                    if existingSize == fileSize {
                        skipped += 1
                        continue
                    }
                }

                if maxBytesPerRescan > 0, remainingBytes <= 0 {
                    hitBudget = true
                    break
                }

                Self.statusLog("rescan: parsing \(url.lastPathComponent) size \(Self.formatBytes(fileSize)) offset \(Self.formatBytes(existingOffset))")
                let fileStart = Date()
                let budgetForFile = maxBytesPerRescan > 0 ? remainingBytes : nil
                if let parsed = importer.parseSession(at: url, modTime: modTime, byteBudget: budgetForFile) {
                    parsedSessions.append(parsed)
                    let duration = Date().timeIntervalSince(fileStart)
                    if duration >= 0.2 {
                        Self.statusLog("rescan: parsed \(url.lastPathComponent) +\(Self.formatBytes(parsed.parsedBytes)) in \(String(format: "%.2fs", duration))")
                    }
                    if maxBytesPerRescan > 0 {
                        remainingBytes = max(0, remainingBytes - parsed.parsedBytes)
                        if parsed.didHitBudget {
                            hitBudget = true
                            break
                        }
                    }
                    if parsed.didUseTail {
                        Self.statusLog("rescan: tail-scan \(url.lastPathComponent) (partial history)")
                    }
                }

                processed += 1
                let now = Date()
                if now.timeIntervalSince(lastProgressLog) >= progressInterval {
                    Self.statusLog("rescan: processed \(processed)/\(fileCount) files (parsed \(parsedSessions.count), skipped \(skipped))")
                    lastProgressLog = now
                }
            }

            let sessions = parsedSessions
            let skippedCount = skipped
            await MainActor.run {
                self.log("rescan: found \(fileCount) files, skipped \(skippedCount), parsed \(sessions.count)")
                Self.statusLog("rescan: completed (parsed \(sessions.count), skipped \(skippedCount), duration \(String(format: "%.2fs", Date().timeIntervalSince(scanStart))))")
                self.apply(sessions)
                self.stats.lastFileCount = fileCount
                self.stats.lastParsedCount = sessions.count
                self.stats.lastSkippedCount = skippedCount
                self.stats.lastRescanDuration = Date().timeIntervalSince(scanStart)
                self.isScanning = false
            }

            if hitBudget {
                await MainActor.run {
                    self.scheduleRescan()
                }
            }
        }
    }

    private func startMonitoring() -> Bool {
        directoryMonitor?.stop()
        let monitor = DirectoryMonitor(url: rootURL)
        monitor.onChange = { [weak self] in
            self?.stats.lastMonitorEventAt = Date()
            self?.scheduleRescan()
        }
        directoryMonitor = monitor
        monitor.start()
        return monitor.isActive
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await MainActor.run {
                    self?.stats.lastPollAt = Date()
                    self?.rescanNow()
                }
            }
        }
    }

    private func shouldEnablePolling(monitoringActive: Bool) -> Bool {
        if ProcessInfo.processInfo.environment["CODEX_ENABLE_POLLING"] == "1" {
            log("polling: forced on via env")
            return true
        }
        if !monitoringActive {
            log("polling: enabled (directory monitor inactive)")
            return true
        }
        log("polling: disabled (directory monitor active)")
        return false
    }

    private func startOutboxProcessing() {
        outboxTask?.cancel()
        #if os(macOS)
        outboxTask = Task { [weak self] in
            let activeDelay: UInt64 = 2_000_000_000
            let idleDelay: UInt64 = 15_000_000_000
            var nextDelay = idleDelay
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nextDelay)
                let hadPending = await MainActor.run {
                    self?.processOutbox() ?? false
                }
                nextDelay = hadPending ? activeDelay : idleDelay
            }
        }
        #endif
    }

    @MainActor
    private func processOutbox() -> Bool {
        #if os(macOS)
        guard let modelContext else { return false }
        let predicate = #Predicate<OutboxMessage> { $0.status == "pending" }
        let descriptor = FetchDescriptor<OutboxMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let pending = (try? modelContext.fetch(descriptor)) ?? []
        stats.lastOutboxRunAt = Date()
        stats.lastOutboxPendingCount = pending.count
        guard !pending.isEmpty else { return false }

        for message in pending {
            message.status = "sending"
            try? modelContext.save()
            Task.detached(priority: .utility) {
                let result = CodexCliSender.send(sessionId: message.sessionId, text: message.text, cwd: message.cwd)
                await MainActor.run {
                    switch result {
                    case .success:
                        message.status = "sent"
                        message.lastError = ""
                    case .failure(let error):
                        message.status = "failed"
                        message.lastError = error.localizedDescription
                    }
                    try? modelContext.save()
                }
            }
        }
        return true
        #endif
        return false
    }

    private func scheduleRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run {
                self?.rescanNow()
            }
        }
    }

    private func apply(_ sessions: [ParsedSession]) {
        guard !sessions.isEmpty, let modelContext else { return }
        func normalize(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let existingSessions = (try? modelContext.fetch(FetchDescriptor<ChatSession>())) ?? []
        var sessionMap: [String: ChatSession] = [:]
        for session in existingSessions {
            if let existing = sessionMap[session.sourcePath] {
                if session.sourceModTime >= existing.sourceModTime {
                    modelContext.delete(existing)
                    sessionMap[session.sourcePath] = session
                } else {
                    modelContext.delete(session)
                }
            } else {
                sessionMap[session.sourcePath] = session
            }
        }

        var didChange = false
        var didDeleteOutbox = false

        for parsed in sessions {
            var newUserTexts: Set<String> = []
            if let existing = sessionMap[parsed.sourcePath] {
                if existing.id != parsed.id { existing.id = parsed.id; didChange = true }
                if existing.sourceModTime != parsed.sourceModTime { existing.sourceModTime = parsed.sourceModTime; didChange = true }
                if existing.sourceFileSize != parsed.sourceFileSize { existing.sourceFileSize = parsed.sourceFileSize; didChange = true }
                if existing.lastParsedOffset != parsed.lastParsedOffset { existing.lastParsedOffset = parsed.lastParsedOffset; didChange = true }
                if existing.sortDate != parsed.lastActivityAt { existing.sortDate = parsed.lastActivityAt; didChange = true }
                if existing.title != parsed.title { existing.title = parsed.title; didChange = true }
                if existing.cwd != parsed.cwd { existing.cwd = parsed.cwd; didChange = true }
                if existing.preview != parsed.preview { existing.preview = parsed.preview; didChange = true }
                let existingMessages = (existing.messages ?? []).sorted { $0.order < $1.order }
                let parsedMessages = parsed.messages

                if existingMessages.isEmpty {
                    existing.messages = parsedMessages.map { message in
                        ChatMessage(role: message.role, content: message.content, order: message.order, session: existing)
                    }
                    didChange = true
                    newUserTexts = Set(parsedMessages.filter { $0.role == "user" }.map { normalize($0.content) })
                } else if existingMessages.count <= parsedMessages.count, messagesMatchPrefix(existingMessages, parsedMessages) {
                    if existingMessages.count < parsedMessages.count {
                        let newMessages = parsedMessages[existingMessages.count...].map { message in
                            ChatMessage(role: message.role, content: message.content, order: message.order, session: existing)
                        }
                        if existing.messages == nil {
                            existing.messages = existingMessages
                        }
                        existing.messages?.append(contentsOf: newMessages)
                        didChange = true
                        newUserTexts = Set(newMessages.filter { $0.role == "user" }.map { normalize($0.content) })
                    }
                } else {
                    for message in existingMessages {
                        modelContext.delete(message)
                    }

                    existing.messages = parsedMessages.map { message in
                        ChatMessage(role: message.role, content: message.content, order: message.order, session: existing)
                    }
                    didChange = true
                    newUserTexts = Set(parsedMessages.filter { $0.role == "user" }.map { normalize($0.content) })
                }
            } else {
                let session = ChatSession(
                    id: parsed.id,
                    sourcePath: parsed.sourcePath,
                    sourceModTime: parsed.sourceModTime,
                    sourceFileSize: parsed.sourceFileSize,
                    lastParsedOffset: parsed.lastParsedOffset,
                    sortDate: parsed.lastActivityAt,
                    title: parsed.title,
                    cwd: parsed.cwd,
                    preview: parsed.preview
                )

                session.messages = parsed.messages.map { message in
                    ChatMessage(role: message.role, content: message.content, order: message.order, session: session)
                }

                modelContext.insert(session)
                didChange = true
                newUserTexts = Set(parsed.messages.filter { $0.role == "user" }.map { normalize($0.content) })
            }

            if !newUserTexts.isEmpty {
                let sessionId = parsed.id
                let predicate = #Predicate<OutboxMessage> { $0.sessionId == sessionId }
                let descriptor = FetchDescriptor<OutboxMessage>(predicate: predicate)
                let outbox = (try? modelContext.fetch(descriptor)) ?? []
                for entry in outbox {
                    if newUserTexts.contains(normalize(entry.text)) {
                        modelContext.delete(entry)
                        didDeleteOutbox = true
                    }
                }
            }
        }

        do {
            guard didChange || didDeleteOutbox else { return }
            try modelContext.save()
            let total = (try? modelContext.fetchCount(FetchDescriptor<ChatSession>())) ?? -1
            log("apply: saved \(sessions.count) sessions")
            log("apply: total sessions \(total)")
        } catch {
            log("apply: save failed \(error)")
        }
    }

    private func log(_ message: String) {
        guard ProcessInfo.processInfo.environment["CODEX_DEBUG_LOG"] == "1" else { return }
        NSLog("[CodexSessionMonitor] %@", message)
    }

    nonisolated private static func statusLog(_ message: String) {
        if ProcessInfo.processInfo.environment["CODEX_STATUS_LOG"] == "0" { return }
        NSLog("[CodexStatus] %@", message)
    }

    nonisolated private static func scanBudgetBytes() -> Int64 {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CODEX_SCAN_BUDGET_BYTES"], let value = Int64(raw), value >= 0 {
            return value
        }
        if let raw = env["CODEX_SCAN_BUDGET_MB"], let value = Double(raw), value >= 0 {
            return Int64(value * 1024.0 * 1024.0)
        }
        return 16 * 1024 * 1024
    }

    nonisolated private static func formatBytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var remaining = Double(max(0, value))
        var unitIndex = 0
        while remaining >= 1024, unitIndex < units.count - 1 {
            remaining /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int64(remaining))\(units[unitIndex])"
        }
        return String(format: "%.1f%@", remaining, units[unitIndex])
    }

    private func messagesMatchPrefix(_ existing: [ChatMessage], _ parsed: [ParsedMessage]) -> Bool {
        guard existing.count <= parsed.count else { return false }
        for (index, message) in existing.enumerated() {
            let parsedMessage = parsed[index]
            if message.role != parsedMessage.role { return false }
            if message.content != parsedMessage.content { return false }
            if message.order != parsedMessage.order { return false }
        }
        return true
    }
}

struct MonitorStats {
    var totalRescans: Int = 0
    var lastRescanAt: Date?
    var lastRescanDuration: TimeInterval = 0
    var lastFileCount: Int = 0
    var lastParsedCount: Int = 0
    var lastSkippedCount: Int = 0
    var lastMonitorEventAt: Date?
    var lastPollAt: Date?
    var monitorActive: Bool = false
    var pollingEnabled: Bool = false
    var lastOutboxRunAt: Date?
    var lastOutboxPendingCount: Int = 0
}
