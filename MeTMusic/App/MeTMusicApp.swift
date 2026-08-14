import SwiftUI

@main
struct MeTMusicApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(.pink)
        }
    }
}
