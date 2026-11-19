import SwiftUI
import Observation

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        content
            #if os(macOS)
            .opacity(store.isPlayerPresented ? 0 : 1)
            #endif
            .allowsHitTesting(!store.isPlayerPresented)
            .accessibilityHidden(store.isPlayerPresented)
            .overlay {
                GeometryReader { geometry in
                    if store.isPlayerPresented {
                        let travel = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                        PlayerPresentationView(travel: travel, usesFade: usesFade) {
                            store.isPlayerPresented = false
                        }
                        .transition(.asymmetric(
                            insertion: usesFade ? .opacity : .offset(y: travel),
                            removal: .identity
                        ))
                    }
                }
                .animation(store.isPlayerPresented ? playerSurfaceAnimation(usesFade: usesFade) : nil,
                           value: store.isPlayerPresented)
                .allowsHitTesting(store.isPlayerPresented)
            }
        #if os(macOS)
        // Keep title-bar visibility and its safe-area reservation stable across
        // player transitions, including when the library has no toolbar items.
        .toolbar(.visible, for: .windowToolbar)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(MacWindowContentBoundary(
            artworkURL: store.currentSong?.bestCoverURL
        ))
        #endif
    }

    private var usesFade: Bool {
        #if os(macOS)
        true
        #else
        reduceMotion
        #endif
    }

    private var content: some View {
        Group {
            tabContent
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

    private var libraryContent: some View {
        LibraryView()
    }

    private var tabContent: some View {
        Group {
            #if os(macOS)
            VStack(spacing: 0) {
                libraryContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.currentSong != nil {
                    MiniPlayerView()
                }
            }
            #else
            libraryContent
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if store.currentSong != nil {
                        MiniPlayerView()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
            #endif
        }
        #if !os(macOS)
        .background(Color(red: 22 / 255, green: 22 / 255, blue: 28 / 255).ignoresSafeArea())
        #endif
        .preferredColorScheme(.dark)
    }

}

/// Only the surface modifier observes frame-by-frame motion. The player content
/// (including artwork and lyrics) does not subscribe to drag offset changes.
@MainActor
@Observable
private final class PlayerPresentationMotion {
    var isClosing = false
    var dragOffset: CGFloat = 0
}

private struct PlayerPresentationView: View {
    @State private var motion = PlayerPresentationMotion()
    let travel: CGFloat
    let usesFade: Bool
    let onDismiss: () -> Void

    var body: some View {
        PlayerView(
            onDismiss: close,
            onDismissDrag: { motion.dragOffset = $0 }
        )
        .modifier(PlayerSurfaceMotion(
            motion: motion,
            travel: travel,
            reduceMotion: usesFade
        ))
        #if os(macOS)
        // Keep the player and its background below the persistent toolbar.
        .clipped()
        .navigationTitle("MeT-Music")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("关闭播放器", systemImage: "xmark", action: close)
                    .keyboardShortcut(.cancelAction)
                    .help("关闭播放器")
            }
        }
        #endif
    }

    private func close() {
        guard !motion.isClosing else { return }
        // Animate the same offset from its current drag position to offscreen;
        // remove the view only after the animation has finished.
        withAnimation(playerSurfaceAnimation(usesFade: usesFade), completionCriteria: .removed) {
            motion.isClosing = true
        } completion: {
            onDismiss()
        }
    }
}

private func playerSurfaceAnimation(usesFade: Bool) -> Animation {
    usesFade ? .easeOut(duration: 0.18) : .spring(duration: 0.38, bounce: 0)
}

private struct PlayerSurfaceMotion: ViewModifier {
    let motion: PlayerPresentationMotion
    let travel: CGFloat
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let offscreen = motion.isClosing
        content
            .offset(y: reduceMotion ? 0 : (offscreen ? travel : motion.dragOffset))
            .opacity(reduceMotion && offscreen ? 0 : 1)
            .allowsHitTesting(!motion.isClosing)
            .accessibilityHidden(motion.isClosing)
    }
}
