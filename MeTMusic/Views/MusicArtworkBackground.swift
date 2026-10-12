import SwiftUI

/// A shared artwork backdrop, independent of the player presentation.
struct MusicArtworkBackground: View {
    let artworkURL: URL?

    var body: some View {
        ZStack {
            Color(red: 0.047, green: 0.047, blue: 0.055)
            if let artworkURL {
                ArtworkView(url: artworkURL, cornerRadius: 0, maxPixelSize: 160)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 60, opaque: true)
            }
            LinearGradient(
                colors: [.black.opacity(0.5), .black.opacity(0.75), Color(red: 0.039, green: 0.039, blue: 0.047).opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder
    func macTransparentScrollBackground() -> some View {
        #if os(macOS)
        scrollContentBackground(.hidden)
        #else
        self
        #endif
    }
}
