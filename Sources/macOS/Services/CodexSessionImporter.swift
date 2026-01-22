import Foundation
import CryptoKit

struct ParsedMessage {
    let role: String
    let content: String
    let order: Int
}

struct ParsedSession {
    let id: String
    let sourcePath: String
    let sourceModTime: Date
    let sourceFileSize: Int64
    let lastParsedOffset: Int64
    let startedAt: Date
    let lastActivityAt: Date
    let title: String
    let cwd: String
    let preview: String
    let messages: [ParsedMessage]
    let parsedBytes: Int64
    let didHitBudget: Bool
    let didUseTail: Bool
}

struct CodexSessionImporter {
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let fallbackDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func discoverSessionFiles(rootURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .nameKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            files.append(url)
        }
        return files
    }

    func parseSession(at url: URL, modTime: Date, byteBudget: Int64? = nil) -> ParsedSession? {
        let fileManager = FileManager.default
        let fileSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0

        var sessionId = url.deletingPathExtension().lastPathComponent
        var startedAt = modTime
        var messages: [ParsedMessage] = []
        var order = 0
        var cwd = ""
        var lastParsedOffset: UInt64 = 0
        var baseLineCount = 0
        var usingCache = false
        var lastActivityAt = startedAt
        var didUseTail = false
        let tailConfig = tailScanConfig()
        var sawTimestamp = false

        let cache = ParsedFileStore.read(sourcePath: url.path)
        if let cache,
           cache.sourceModTime <= modTime,
           cache.lastParsedOffset > 0,
           cache.lastParsedOffset <= fileSize {
            sessionId = cache.id
            startedAt = cache.startedAt
            cwd = cache.cwd
            messages = cache.messages.map { ParsedMessage(role: $0.role, content: $0.content, order: $0.order) }
            order = messages.count
            lastParsedOffset = cache.lastParsedOffset
            baseLineCount = cache.lastParsedLineCount
            lastActivityAt = cache.lastActivityAt
            usingCache = true
        }

        if tailConfig.enabled, fileSize > tailConfig.thresholdBytes {
            if let cache {
                if cache.id.isEmpty == false { sessionId = cache.id }
                if cache.startedAt != Foundation.Date.distantPast { startedAt = cache.startedAt }
                if cache.cwd.isEmpty == false { cwd = cache.cwd }
                if cache.lastActivityAt > lastActivityAt { lastActivityAt = cache.lastActivityAt }
            }
            let tailBytes = min(fileSize, tailConfig.tailBytes)
            lastParsedOffset = fileSize - tailBytes
            baseLineCount = 0
            messages = []
            order = 0
            usingCache = false
            didUseTail = true
        }

        if lastParsedOffset > fileSize {
            sessionId = url.deletingPathExtension().lastPathComponent
            startedAt = modTime
            messages = []
            order = 0
            cwd = ""
            lastParsedOffset = 0
            baseLineCount = 0
            usingCache = false
            lastActivityAt = startedAt
        }

        if !usingCache, !didUseTail {
            if tailConfig.enabled, fileSize > tailConfig.thresholdBytes {
                let head = scanHeadMetadata(url: url, byteLimit: tailConfig.headBytes)
                if let id = head.id { sessionId = id }
                if let date = head.startedAt { startedAt = date }
                if let cwdValue = head.cwd { cwd = cwdValue }
                lastActivityAt = head.lastActivityAt ?? lastActivityAt
                let tailBytes = min(fileSize, tailConfig.tailBytes)
                lastParsedOffset = fileSize - tailBytes
                didUseTail = true
            }
        }

        let startOffset = lastParsedOffset
        guard var reader = LineReader(
            url: url,
            startingOffset: lastParsedOffset,
            maxLineBytes: maxLineBytes(),
            skipLargeLines: true
        ) else { return nil }
        defer { reader.close() }

        var newLines = 0
        var didHitBudget = false

        if startOffset > 0 {
            let advanced = reader.skipToNextLine()
            if !advanced {
                lastParsedOffset = fileSize
            }
        }

        while let (line, endOffset, wasTruncated) = reader.nextLine() {
            newLines += 1
            lastParsedOffset = endOffset

            if wasTruncated { continue }
            guard !line.isEmpty else { continue }
            let isSessionMeta = line.contains("\"type\":\"session_meta\"")
            let isResponseItem = line.contains("\"type\":\"response_item\"")
            guard isSessionMeta || isResponseItem else { continue }

            if isResponseItem && !line.contains("\"type\":\"message\"") {
                continue
            }

            guard let json = decodeJSON(from: line) else { continue }
            if let timestamp = json["timestamp"] as? String,
               let date = dateFormatter.date(from: timestamp) ?? fallbackDateFormatter.date(from: timestamp),
               date > lastActivityAt {
                lastActivityAt = date
                sawTimestamp = true
            }
            guard let type = json["type"] as? String else { continue }

            if type == "session_meta", let payload = json["payload"] as? [String: Any] {
                if let id = payload["id"] as? String {
                    sessionId = id
                }
                if let timestamp = payload["timestamp"] as? String {
                    if let date = dateFormatter.date(from: timestamp) ?? fallbackDateFormatter.date(from: timestamp) {
                        startedAt = date
                    }
                }
                if let cwdValue = payload["cwd"] as? String {
                    cwd = cwdValue
                }
                continue
            }

            if type == "response_item", let payload = json["payload"] as? [String: Any] {
                guard payload["type"] as? String == "message" else { continue }
                guard let role = payload["role"] as? String else { continue }
                guard role == "user" || role == "assistant" else { continue }

                let text = extractText(from: payload["content"])
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                messages.append(ParsedMessage(role: role, content: text, order: order))
                order += 1
            }

            if let budget = byteBudget, budget > 0 {
                let parsedBytes = Int64(lastParsedOffset) - Int64(startOffset)
                if parsedBytes >= budget {
                    didHitBudget = true
                    break
                }
            }
        }

        let totalLineCount = baseLineCount + newLines
        if !usingCache {
            messages = normalizeMessages(messages)
        }

        let title = cwd.isEmpty ? url.deletingPathExtension().lastPathComponent : cwd
        let preview = makePreview(from: messages.last?.content ?? "")
        if !sawTimestamp || didHitBudget || didUseTail {
            if modTime > lastActivityAt {
                lastActivityAt = modTime
            }
        }

        let parsedBytes = Int64(lastParsedOffset) - Int64(startOffset)
        let parsed = ParsedSession(
            id: sessionId,
            sourcePath: url.path,
            sourceModTime: modTime,
            sourceFileSize: Int64(fileSize),
            lastParsedOffset: Int64(lastParsedOffset),
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            title: title,
            cwd: cwd,
            preview: preview,
            messages: messages,
            parsedBytes: parsedBytes,
            didHitBudget: didHitBudget,
            didUseTail: didUseTail
        )

        ParsedFileStore.write(parsed, lastParsedOffset: lastParsedOffset, lastParsedLineCount: totalLineCount)
        return parsed
    }

    private func decodeJSON(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func extractText(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        guard let items = content as? [[String: Any]] else { return "" }
        var parts: [String] = []

        for item in items {
            guard let type = item["type"] as? String else { continue }
            if type == "input_text" || type == "output_text" || type == "text" {
                if let text = item["text"] as? String {
                    parts.append(text)
                }
            }
        }

        return parts.joined()
    }

    private func normalizeMessages(_ messages: [ParsedMessage]) -> [ParsedMessage] {
        let trimmed = dropLeadingBootstrapMessages(messages)
        return trimmed.enumerated().map { index, message in
            ParsedMessage(role: message.role, content: message.content, order: index)
        }
    }

    private func dropLeadingBootstrapMessages(_ messages: [ParsedMessage]) -> [ParsedMessage] {
        var index = 0
        while index < messages.count {
            let message = messages[index]
            if message.role == "user", isBootstrapText(message.content) {
                index += 1
                continue
            }
            break
        }
        return Array(messages.dropFirst(index))
    }

    private func isBootstrapText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("agents.md instructions")
            || lowered.contains("<environment_context>")
            || lowered.contains("<instructions>")
            || lowered.contains("## skills")
    }

    private func makePreview(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let singleLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 140 { return singleLine }
        let index = singleLine.index(singleLine.startIndex, offsetBy: 140)
        return String(singleLine[..<index]) + "…"
    }

    private func maxLineBytes() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CODEX_MAX_LINE_BYTES"], let value = Int(raw), value > 0 {
            return value
        }
        if let raw = env["CODEX_MAX_LINE_MB"], let value = Double(raw), value > 0 {
            return Int(value * 1024.0 * 1024.0)
        }
        return 2 * 1024 * 1024
    }

    private struct TailConfig {
        let enabled: Bool
        let thresholdBytes: UInt64
        let tailBytes: UInt64
        let headBytes: Int64
    }

    private func tailScanConfig() -> TailConfig {
        let env = ProcessInfo.processInfo.environment
        let thresholdMB = Double(env["CODEX_TAIL_THRESHOLD_MB"] ?? "") ?? 256
        let tailMB = Double(env["CODEX_TAIL_BYTES_MB"] ?? "") ?? 8
        let headMB = Double(env["CODEX_HEAD_BYTES_MB"] ?? "") ?? 0.25

        let thresholdBytes = UInt64(max(0, thresholdMB) * 1024.0 * 1024.0)
        let tailBytes = UInt64(max(0, tailMB) * 1024.0 * 1024.0)
        let headBytes = Int64(max(0, headMB) * 1024.0 * 1024.0)

        let enabled = thresholdBytes > 0 && tailBytes > 0
        return TailConfig(enabled: enabled, thresholdBytes: thresholdBytes, tailBytes: tailBytes, headBytes: max(64 * 1024, headBytes))
    }

    private struct HeadMetadata {
        let id: String?
        let startedAt: Date?
        let cwd: String?
        let lastActivityAt: Date?
    }

    private func scanHeadMetadata(url: URL, byteLimit: Int64) -> HeadMetadata {
        guard var reader = LineReader(
            url: url,
            startingOffset: 0,
            maxLineBytes: maxLineBytes(),
            skipLargeLines: true
        ) else {
            return HeadMetadata(id: nil, startedAt: nil, cwd: nil, lastActivityAt: nil)
        }
        defer { reader.close() }

        var id: String?
        var startedAt: Date?
        var cwd: String?
        var lastActivityAt: Date?

        while let (line, endOffset, wasTruncated) = reader.nextLine() {
            if wasTruncated { continue }
            guard !line.isEmpty else { continue }
            if let timestamp = extractTimestamp(from: line) {
                if lastActivityAt == nil || timestamp > lastActivityAt! {
                    lastActivityAt = timestamp
                }
            }
            guard line.contains("\"type\":\"session_meta\"") else {
                if endOffset >= UInt64(byteLimit) { break }
                continue
            }
            guard let json = decodeJSON(from: line) else { continue }
            guard let payload = json["payload"] as? [String: Any] else { continue }
            if id == nil, let value = payload["id"] as? String {
                id = value
            }
            if startedAt == nil, let timestamp = payload["timestamp"] as? String {
                startedAt = dateFormatter.date(from: timestamp) ?? fallbackDateFormatter.date(from: timestamp)
            }
            if cwd == nil, let value = payload["cwd"] as? String {
                cwd = value
            }
            break
        }

        return HeadMetadata(id: id, startedAt: startedAt, cwd: cwd, lastActivityAt: lastActivityAt)
    }

    private func extractTimestamp(from line: String) -> Date? {
        guard let range = line.range(of: "\"timestamp\":\"") else { return nil }
        let start = range.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else { return nil }
        let value = String(line[start..<end])
        return dateFormatter.date(from: value) ?? fallbackDateFormatter.date(from: value)
    }

    private struct LineReader {
        private let handle: FileHandle
        private var buffer = Data()
        private var lineStartOffset: UInt64
        private var readOffset: UInt64
        private var discarding = false
        private let maxLineBytes: Int
        private let skipLargeLines: Bool
        private let chunkSize = 64 * 1024
        private let newline = Data([0x0A])

        init?(url: URL, startingOffset: UInt64, maxLineBytes: Int, skipLargeLines: Bool) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            self.handle = handle
            do {
                try handle.seek(toOffset: startingOffset)
            } catch {
                return nil
            }
            self.lineStartOffset = startingOffset
            self.readOffset = startingOffset
            self.maxLineBytes = maxLineBytes
            self.skipLargeLines = skipLargeLines
        }

        mutating func nextLine() -> (String, UInt64, Bool)? {
            while true {
                if !discarding, let range = buffer.firstRange(of: newline) {
                    let lineData = buffer.subdata(in: 0..<range.lowerBound)
                    let endOffset = lineStartOffset + UInt64(range.lowerBound) + 1
                    buffer.removeSubrange(0..<range.upperBound)
                    lineStartOffset = endOffset
                    let line = String(data: lineData, encoding: .utf8) ?? ""
                    return (line, endOffset, false)
                }

                let data = try? handle.read(upToCount: chunkSize)
                guard let data, !data.isEmpty else {
                    return nil
                }
                readOffset += UInt64(data.count)

                if discarding {
                    if let range = data.firstRange(of: newline) {
                        let endOffset = readOffset - UInt64(data.count - range.lowerBound - 1)
                        lineStartOffset = endOffset
                        discarding = false
                        return ("", endOffset, true)
                    }
                    continue
                }

                buffer.append(data)
                if skipLargeLines, buffer.count > maxLineBytes {
                    buffer.removeAll(keepingCapacity: true)
                    discarding = true
                }
            }
        }

        mutating func skipToNextLine() -> Bool {
            while let (line, _, wasTruncated) = nextLine() {
                if wasTruncated {
                    return true
                }
                if !line.isEmpty {
                    return true
                }
            }
            return false
        }

        func close() {
            try? handle.close()
        }
    }
}

enum ParsedFileStore {
    struct CacheMessage: Codable {
        let role: String
        let content: String
        let order: Int
    }

    struct CacheSession: Codable {
        let id: String
        let sourcePath: String
        let sourceModTime: Date
        let startedAt: Date
        let title: String
        let cwd: String
        let preview: String
        let messages: [CacheMessage]
        var lastParsedOffset: UInt64 = 0
        var lastParsedLineCount: Int = 0
        var lastActivityAt: Date = Foundation.Date.distantPast
    }

    static func write(_ session: ParsedSession, lastParsedOffset: UInt64, lastParsedLineCount: Int) {
        let cache = CacheSession(
            id: session.id,
            sourcePath: session.sourcePath,
            sourceModTime: session.sourceModTime,
            startedAt: session.startedAt,
            title: session.title,
            cwd: session.cwd,
            preview: session.preview,
            messages: session.messages.map { CacheMessage(role: $0.role, content: $0.content, order: $0.order) },
            lastParsedOffset: lastParsedOffset,
            lastParsedLineCount: lastParsedLineCount,
            lastActivityAt: session.lastActivityAt
        )

        do {
            let url = try cacheURL(for: session.sourcePath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cache)
            try data.write(to: url, options: [.atomic])
        } catch {
            return
        }
    }

    static func read(sourcePath: String) -> CacheSession? {
        do {
            let url = try cacheURL(for: sourcePath)
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CacheSession.self, from: data)
        } catch {
            return nil
        }
    }

    private static func cacheURL(for sourcePath: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("CodexSessions/Parsed", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let hash = sha256(sourcePath)
        return directory.appendingPathComponent("\(hash).json")
    }

    private static func sha256(_ value: String) -> String {
        let data = Data(value.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
