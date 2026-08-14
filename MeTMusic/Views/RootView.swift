import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    @ViewBuilder
    var body: some View {
        ZStack {
            content
            if store.isPlayerPresented {
                PlayerView(onDismiss: { store.isPlayerPresented = false })
                    // Keep the fade transaction on the overlay. Animating the
                    // whole ZStack also animates the hidden mini player and can
                    // make symbol transformers span two presentation screens.
                    .transition(.opacity.animation(.easeInOut(duration: 0.24)))
                    .zIndex(10)
            }
        }
    }

    private var content: some View {
        Group {
            if store.isLoggedIn {
                tabContent
            } else {
                LoginView()
            }
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
    }

    @ViewBuilder
    private var tabContent: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if store.currentSong != nil, !store.isPlayerPresented {
                tabs.tabViewBottomAccessory {
                    MiniPlayerView(usesSystemGlass: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            } else {
                tabs
            }
        } else {
            if store.currentSong != nil, !store.isPlayerPresented {
                tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                    MiniPlayerView()
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
            } else {
                tabs
            }
        }
        #else
        if store.currentSong != nil, !store.isPlayerPresented {
            tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayerView().padding(.horizontal, 10).padding(.bottom, 6)
            }
        } else {
            tabs
        }
        #endif
    }

    private var tabs: some View {
        TabView {
            LibraryView()
                .tabItem { Label("音乐库", systemImage: "music.note.list") }
            ListenTogetherView()
                .tabItem { Label("一起听", systemImage: "shareplay") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
