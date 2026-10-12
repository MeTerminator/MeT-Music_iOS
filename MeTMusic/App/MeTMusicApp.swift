import SwiftUI

@main
struct MeTMusicApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        #if os(macOS)
        Window("MeT-Music", id: "main") {
            root
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("显示主窗口") { openMainWindow() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("播放") {
                Button(store.audio.isPlaying ? "暂停" : "播放") { store.togglePlayback() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(store.currentSong == nil)
                Button("上一首") { store.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(store.currentSong == nil)
                Button("下一首") { store.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(store.currentSong == nil)
                Divider()
                Button(store.isPlayerPresented ? "关闭播放器" : "显示播放器") {
                    store.isPlayerPresented.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(store.currentSong == nil)
            }
        }
        Settings {
            SettingsView()
                .environmentObject(store)
                .tint(.pink)
                .frame(width: 640, height: 680)
        }
        #else
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(.pink)
        }
        #endif
    }

    private var root: some View {
        RootView().environmentObject(store).tint(.pink)
    }

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow

    private func openMainWindow() { openWindow(id: "main") }
    #endif
}
