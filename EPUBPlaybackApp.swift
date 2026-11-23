import SwiftData
import SwiftUI

@main
struct EPUBPlaybackApp: App {
    private let sharedModelContainer: ModelContainer = SyncManager.createModelContainer()

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(sharedModelContainer)
    }
}
