import SwiftUI
import Observation

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    @ViewBuilder
    var body: some View {
        ZStack {
            content
                .opacity(store.isPlayerPresented ? 0 : 1)
                .allowsHitTesting(!store.isPlayerPresented)
                .accessibilityHidden(store.isPlayerPresented)
            if store.isPlayerPresented {
                PlayerPresentationView(onDismiss: { store.isPlayerPresented = false })
                    .zIndex(10)
            }
        }
        #if os(macOS)
        .toolbar(store.isPlayerPresented ? .hidden : .automatic, for: .windowToolbar)
        #endif
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
    private var libraryContent: some View {
        #if os(macOS)
        MacLibraryView()
        #else
        LibraryView()
        #endif
    }

    private var tabContent: some View {
        VStack(spacing: 0) {
            libraryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.currentSong != nil {
                MiniPlayerView()
            }
        }
        .background(Color(red: 22 / 255, green: 22 / 255, blue: 28 / 255).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

}

/// Only the surface modifier observes frame-by-frame motion. The player content
/// (including artwork and lyrics) does not subscribe to drag offset changes.
@MainActor
@Observable
private final class PlayerPresentationMotion {
    enum Phase { case hidden, opening, open, closing }
    var phase = Phase.hidden
    var dragOffset: CGFloat = 0
}

private struct PlayerPresentationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = PlayerPresentationMotion()
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            PlayerView(
                onDismiss: close,
                onDismissDrag: { motion.dragOffset = $0 }
            )
            .modifier(PlayerSurfaceMotion(
                motion: motion,
                travel: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom,
                reduceMotion: usesFadeTransition
            ))
        }
        #if os(macOS)
        .background {
            Button("关闭播放器", action: close)
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        }
        #endif
        .task {
            // Mount and lay out the surface offscreen before beginning its entrance.
            await Task.yield()
            guard !Task.isCancelled, motion.phase == .hidden else { return }
            withAnimation(animation, completionCriteria: .removed) {
                motion.phase = .opening
            } completion: {
                if motion.phase == .opening { motion.phase = .open }
            }
        }
    }

    private var usesFadeTransition: Bool {
        #if os(macOS)
        true
        #else
        reduceMotion
        #endif
    }

    private var animation: Animation {
        usesFadeTransition ? .easeOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 1)
    }

    private func close() {
        guard motion.phase == .open else { return }
        // Animate the same offset from its current drag position to offscreen;
        // remove the view only after the animation has finished.
        withAnimation(animation, completionCriteria: .removed) {
            motion.phase = .closing
        } completion: {
            onDismiss()
        }
    }
}

private struct PlayerSurfaceMotion: ViewModifier {
    let motion: PlayerPresentationMotion
    let travel: CGFloat
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let offscreen = motion.phase == .hidden || motion.phase == .closing
        content
            .offset(y: reduceMotion ? 0 : (offscreen ? travel : motion.dragOffset))
            .opacity(reduceMotion && offscreen ? 0 : 1)
            .allowsHitTesting(motion.phase == .open)
            .accessibilityHidden(motion.phase != .open)
    }
}
