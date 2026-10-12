#if os(macOS)
import AppKit
import SwiftUI

/// Observes native scroll input inside the lyric viewport without intercepting
/// it. Programmatic ScrollViewReader updates do not generate wheel events.
struct LyricScrollWheelObserver: NSViewRepresentable {
    let onVerticalScroll: @MainActor () -> Void

    func makeNSView(context: Context) -> LyricScrollWheelView {
        let view = LyricScrollWheelView()
        view.onVerticalScroll = onVerticalScroll
        return view
    }

    func updateNSView(_ view: LyricScrollWheelView, context: Context) {
        view.onVerticalScroll = onVerticalScroll
    }

    static func dismantleNSView(_ view: LyricScrollWheelView, coordinator: ()) {
        view.stopMonitoring()
        view.onVerticalScroll = nil
    }
}

final class LyricScrollWheelView: NSView {
    var onVerticalScroll: (@MainActor () -> Void)?
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // AppKit dispatches local event monitors on the main thread.
            MainActor.assumeIsolated {
                guard let self, let window = self.window,
                      event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      event.scrollingDeltaY != 0,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil))
                else { return }
                self.onVerticalScroll?()
            }
            return event
        }
    }

    func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }
}
#endif
