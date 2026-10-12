#if os(macOS)
  import AppKit
  import SwiftUI

  /// Keep content below the native toolbar throughout player transitions.
  struct MacWindowContentBoundary: NSViewRepresentable {
    @EnvironmentObject private var store: AppStore
    var artworkURL: URL?

    func makeNSView(context: Context) -> BoundaryView {
      let view = BoundaryView()
      view.store = store
      view.artworkURL = artworkURL
      return view
    }

    func updateNSView(_ nsView: BoundaryView, context: Context) {
      nsView.store = store
      nsView.artworkURL = artworkURL
      nsView.restoreContentBoundary()
    }

    static func dismantleNSView(_ nsView: BoundaryView, coordinator: ()) {
      nsView.removeBackdrop()
    }

    final class BoundaryView: NSView {
      var store: AppStore?
      var artworkURL: URL? {
        didSet {
          if artworkURL != oldValue, let store {
            backdrop?.rootView = WindowBackdrop(store: store, artworkURL: artworkURL)
          }
        }
      }
      private var backdrop: BackdropView?

      func removeBackdrop() {
        backdrop?.removeFromSuperview()
        backdrop = nil
      }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeBackdrop() }
        restoreContentBoundary()
      }

      func restoreContentBoundary() {
        guard let window else { return }
        if window.styleMask.contains(.fullSizeContentView) {
          let frame = window.frame
          window.styleMask.remove(.fullSizeContentView)
          window.setFrame(frame, display: false)
        }
        // Draw beneath both the content and native toolbar, without allowing
        // foreground navigation views to extend underneath window controls.
        if let store, let contentView = window.contentView, let frameView = contentView.superview {
          if backdrop?.superview !== frameView {
            removeBackdrop()
            let view = BackdropView(rootView: WindowBackdrop(store: store, artworkURL: artworkURL))
            view.sizingOptions = []
            view.frame = frameView.bounds
            view.autoresizingMask = [.width, .height]
            frameView.addSubview(view, positioned: .below, relativeTo: contentView)
            backdrop = view
          }
        }
        window.titlebarAppearsTransparent = true
      }
    }

    private struct WindowBackdrop: View {
      let store: AppStore
      let artworkURL: URL?

      var body: some View {
        MusicArtworkBackground(artworkURL: artworkURL)
          .environmentObject(store)
      }
    }

    private final class BackdropView: NSHostingView<WindowBackdrop> {
      override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
  }

  struct DesktopCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
      VStack(alignment: .leading, spacing: 18) {
        Label(title, systemImage: symbol)
          .font(.headline)
          .foregroundStyle(.primary)
        content()
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
      .overlay {
        RoundedRectangle(cornerRadius: 18)
          .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
      }
    }
  }
#endif
