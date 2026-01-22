import Foundation
import SwiftData
#if os(macOS)
import Security
#endif

enum ModelContainerFactory {
    static func make() -> ModelContainer {
        let cloudKitContainer = ProcessInfo.processInfo.environment["CODEX_CLOUDKIT_CONTAINER"]
            ?? "iCloud.com.example.CodexSessions"
        let storeURL = appSupportDirectory()
            .appendingPathComponent("CodexSessions", isDirectory: true)
            .appendingPathComponent("CodexSessions.store")

        debugLog("storeURL=\(storeURL.path)")

        if ProcessInfo.processInfo.environment["CODEX_DISABLE_CLOUDKIT"] == "1" {
            debugLog("CloudKit disabled via env")
            let localConfig = ModelConfiguration(url: storeURL)
            return try! ModelContainer(for: ChatSession.self, ChatMessage.self, OutboxMessage.self, configurations: localConfig)
        }

        if hasCloudKitEntitlement() {
            debugLog("CloudKit enabled")
            let cloudConfig = ModelConfiguration(url: storeURL, cloudKitDatabase: .private(cloudKitContainer))
            do {
                return try ModelContainer(for: ChatSession.self, ChatMessage.self, OutboxMessage.self, configurations: cloudConfig)
            } catch {
                debugLog("CloudKit init failed: \(error)")
                // Fall back to a local-only store if CloudKit isn't configured yet.
                let localConfig = ModelConfiguration(url: storeURL)
                return try! ModelContainer(for: ChatSession.self, ChatMessage.self, OutboxMessage.self, configurations: localConfig)
            }
        } else {
            debugLog("CloudKit entitlement missing; using local store")
            let localConfig = ModelConfiguration(url: storeURL)
            return try! ModelContainer(for: ChatSession.self, ChatMessage.self, OutboxMessage.self, configurations: localConfig)
        }
    }

    private static func appSupportDirectory() -> URL {
        (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
    }

    private static func hasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else {
            return false
        }
        if let services = value as? [String] {
            return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
        }
        return false
        #else
        return true
        #endif
    }

    private static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["CODEX_DEBUG_LOG"] == "1" else { return }
        NSLog("[ModelContainerFactory] %@", message)
    }
}
