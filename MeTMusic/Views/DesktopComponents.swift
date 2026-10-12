#if os(macOS)
  import AppKit
  import SwiftUI

  /// Keep content below the native toolbar throughout player transitions.
  struct MacWindowContentBoundary: NSViewRepresentable {
    var isPlayerPresented: Bool

    func makeNSView(context: Context) -> BoundaryView {
      let view = BoundaryView()
      view.isPlayerPresented = isPlayerPresented
      return view
    }

    func updateNSView(_ nsView: BoundaryView, context: Context) {
      nsView.isPlayerPresented = isPlayerPresented
      nsView.restoreContentBoundary()
      DispatchQueue.main.async { [weak nsView] in
        nsView?.restoreTitleVisibility()
      }
    }

    final class BoundaryView: NSView {
      var isPlayerPresented = false

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreContentBoundary()
      }

      override func layout() {
        super.layout()
        restoreTitleVisibility()
      }

      func restoreContentBoundary() {
        guard let window else { return }
        if window.styleMask.contains(.fullSizeContentView) {
          let frame = window.frame
          window.styleMask.remove(.fullSizeContentView)
          window.setFrame(frame, display: false)
        }
        window.titlebarAppearsTransparent = false
        restoreTitleVisibility()
      }

      func restoreTitleVisibility() {
        guard let window else { return }
        let visibility: NSWindow.TitleVisibility = isPlayerPresented ? .hidden : .visible
        if window.titleVisibility != visibility { window.titleVisibility = visibility }
      }
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
