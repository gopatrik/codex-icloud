import SwiftUI
import SwiftData

@main
struct CodexSessionsApp: App {
    private let modelContainer: ModelContainer

    init() {
        modelContainer = ModelContainerFactory.make()
    }

    var body: some Scene {
        WindowGroup {
            SessionListView()
        }
        .modelContainer(modelContainer)
    }
}
