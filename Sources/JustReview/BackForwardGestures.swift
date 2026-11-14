import AppKit
import SwiftUI

/// Back/forward with the trackpad's "Swipe between pages" gesture, however it's set in System
/// Settings → Trackpad (two fingers, three fingers or either), and with a mouse's side buttons,
/// like Finder and Safari. AppKit delivers these but nothing acts on them unless the app does.
private struct BackForwardGestures: ViewModifier {
    @ObservedObject var model: RepoModel
    @ObservedObject var handle: WindowHandle
    @StateObject private var monitor = Box<Any?>(nil)

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor.value == nil else { return }
                monitor.value = NSEvent.addLocalMonitorForEvents(
                    matching: [.swipe, .scrollWheel, .otherMouseUp]
                ) { event in
                    // Local monitors run on the main thread.
                    MainActor.assumeIsolated { perform(event) } ? nil : event
                }
            }
            .onDisappear {
                if let token = monitor.value { NSEvent.removeMonitor(token) }
                monitor.value = nil
            }
    }

    /// Acts on a page swipe or side-button click in this window; true when it was used.
    @MainActor
    private func perform(_ event: NSEvent) -> Bool {
        guard event.window != nil, event.window === handle.window, handle.showsChrome else { return false }
        switch event.type {
        // Three-finger swipes arrive only when the setting includes three fingers.
        // A swipe to the right (fingers moving left to right) goes back, as in Safari.
        case .swipe where event.deltaX > 0: go(back: true)
        case .swipe where event.deltaX < 0: go(back: false)
        case .scrollWheel: return trackTwoFingerSwipe(event)
        case .otherMouseUp where event.buttonNumber == 3: go(back: true)
        case .otherMouseUp where event.buttonNumber == 4: go(back: false)
        default: return false
        }
        return true
    }

    @MainActor
    private func go(back: Bool) {
        if back {
            if model.canGoBack { model.goBack() }
        } else if model.canGoForward {
            model.goForward()
        }
    }

    /// Two-finger swipes (when the setting includes them) arrive as horizontal scrolling. They
    /// turn into a page swipe only where nothing under the pointer can scroll further that way,
    /// so long unwrapped lines still scroll sideways first — as in Safari.
    @MainActor
    private func trackTwoFingerSwipe(_ event: NSEvent) -> Bool {
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              event.phase == .began, event.momentumPhase == [],
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
              !canScrollHorizontally(event)
        else { return false }
        let canGoBack = model.canGoBack, canGoForward = model.canGoForward
        guard canGoBack || canGoForward else { return false }
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: canGoForward ? -1 : 0,
                              max: canGoBack ? 1 : 0) { amount, phase, _, _ in
            // Positive: a swipe to the right, i.e. back.
            if phase == .ended, amount != 0 {
                MainActor.assumeIsolated { go(back: amount > 0) }
            }
        }
        return true
    }

    /// Whether a scroll view under the pointer can still scroll in the event's direction.
    @MainActor
    private func canScrollHorizontally(_ event: NSEvent) -> Bool {
        guard let contentView = event.window?.contentView,
              let hit = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
        else { return false }
        var scrollView = hit as? NSScrollView ?? hit.enclosingScrollView
        while let view = scrollView {
            if let document = view.documentView {
                let x = view.contentView.bounds.minX
                let maxX = document.frame.width - view.contentView.bounds.width
                // Content moving right (positive delta) scrolls toward its left edge.
                if event.scrollingDeltaX > 0 ? x > 0.5 : x < maxX - 0.5 { return true }
            }
            scrollView = view.enclosingScrollView
        }
        return false
    }
}

extension View {
    func backForwardGestures(model: RepoModel, handle: WindowHandle) -> some View {
        modifier(BackForwardGestures(model: model, handle: handle))
    }
}
