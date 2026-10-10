import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    @ViewBuilder
    var body: some View {
        ZStack {
            content
            if store.isPlayerPresented {
                PlayerView(onDismiss: { store.isPlayerPresented = false })
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: store.isPlayerPresented)
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

    private var tabContent: some View {
        LibraryView()
            .background(Color(red: 22 / 255, green: 22 / 255, blue: 28 / 255).ignoresSafeArea())
            .preferredColorScheme(.dark)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.currentSong != nil {
                    MiniPlayerView()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
    }
}
