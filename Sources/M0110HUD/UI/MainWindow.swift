import AppKit
import QuartzCore
import SwiftUI

/// What the window's size depends on: the sidebar owns the width, the keycode
/// picker owns the height.
struct WindowLayout: Equatable {
    var sidebarVisible: Bool
    var pickerOpen: Bool
}

/// Hosts `RootView`. Kept separate from the HUD so the app can run as a menu
/// bar agent with no window at all.
final class MainWindowController: NSObject, NSWindowDelegate {
    /// Fires when the window is closed, so the app can drop back to being a
    /// menu bar agent with no Dock icon.
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) { onClose?() }

    /// The window cannot be resized by hand. Each dimension has exactly two
    /// values, and both follow what the interface is showing.
    ///
    /// The board is drawn at its own maximum, so a wider window would only add
    /// empty background and a narrower one could only crop the thing the app
    /// exists to show. Hiding the sidebar frees precisely the width the sidebar
    /// occupied, and closing the keycode picker frees precisely its height, so
    /// the window hands each back rather than leaving a gap, and the board
    /// itself stays exactly the same size through all four combinations.

    /// Widest thing in the window: the sidebar and its margins, the detail
    /// pane's padding, the board panel's padding, and the board at its cap.
    static let expandedWidth: CGFloat = 1340
    static var collapsedWidth: CGFloat { expandedWidth - RootView.sidebarSpan }

    /// Where the board panel's bottom edge lands, plus its margin.
    static let boardHeight: CGFloat = 613
    /// Where the keycode picker's panel ends, plus its margin.
    static let pickerHeight: CGFloat = 820

    static func size(for layout: WindowLayout) -> NSSize {
        NSSize(width: layout.sidebarVisible ? expandedWidth : collapsedWidth,
               height: layout.pickerOpen ? pickerHeight : boardHeight)
    }

    /// How far the window controls are nudged in from where AppKit puts them.
    ///
    /// AppKit pins them to the window's own corner, which is exactly where the
    /// floating sidebar's rounded edge runs, so left alone the close button
    /// straddles it. Moving them in and down seats them properly on the panel.
    private static let controlOffset = CGVector(dx: 11, dy: 9)
    /// Vertical centre of the window controls, from the window's top edge,
    /// after that nudge. `RootView` lines the sidebar toggle up with it, so it
    /// lives here next to the offset that decides it rather than being a second
    /// number to keep in step.
    static var controlCentreY: CGFloat { 19 + controlOffset.dy }
    /// Where the row of controls ends horizontally.
    static var controlsTrailingX: CGFloat { 74 + controlOffset.dx }
    private static let controlTypes: [NSWindow.ButtonType] =
        [.closeButton, .miniaturizeButton, .zoomButton]

    /// Where AppKit put each button, captured before anything is moved, so a
    /// re-layout can be corrected from the original rather than compounding.
    private var controlOrigins: [NSWindow.ButtonType: NSPoint] = [:]
    private var resizeObserver: NSObjectProtocol?

    private var window: NSWindow?
    private let controller: KeyboardController

    init(controller: KeyboardController) {
        self.controller = controller
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let opening = Self.size(for: WindowLayout(sidebarVisible: true, pickerOpen: false))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: opening),
                         // No `.resizable`: min and max alone would stop a drag
                         // but still offer a resize cursor and a live zoom
                         // button, which invites a gesture that does nothing.
                         styleMask: [.titled, .closable, .miniaturizable,
                                     .fullSizeContentView],
                         backing: .buffered,
                         defer: false)
        window = w
        w.contentView = NSHostingView(rootView: RootView(
            controller: controller,
            onLayoutChange: { [weak self] layout in
                MainActor.assumeIsolated { self?.resize(to: layout) }
            }))
        w.title = "M0110"
        // The theme paints its own ground, so let it run under the title bar.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        // The minimum has to leave the board readable: below roughly this
        // height the keyboard, its toolbar and the keycode picker stop fitting
        // together and the pane turns into a scroll of fragments. The style
        // mask already forbids resizing, but pinning both bounds keeps anything
        // that sets a frame programmatically (a restored frame, a zoom, a Stage
        // Manager tile) at a valid size.
        w.minSize = opening
        w.maxSize = opening
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self

        placeWindowControls()
        // AppKit re-lays the titlebar out on resize, which puts the buttons
        // back; correcting them from their captured originals keeps the nudge
        // stable rather than drifting further each time.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeWindowControls() }
            }

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Roughly the `response` of the SwiftUI spring the sidebar slides on, so
    /// the panel and the window edge read as one movement rather than two.
    private static let resizeDuration: TimeInterval = 0.34

    /// Match the window to what the interface is showing.
    private func resize(to layout: WindowLayout) {
        guard let window else { return }
        let target = Self.size(for: layout)
        let current = window.frame.size
        guard abs(current.width - target.width) > 0.5
                || abs(current.height - target.height) > 0.5 else { return }

        // Open the bounds up to span both sizes first. They are normally pinned
        // to the exact current size to keep the window unresizable, and
        // `setFrame` clamps against them, so animating with them still pinned
        // clamps every intermediate frame to the destination and the animation
        // becomes a jump.
        window.minSize = NSSize(width: min(current.width, target.width),
                                height: min(current.height, target.height))
        window.maxSize = NSSize(width: max(current.width, target.width),
                                height: max(current.height, target.height))

        var frame = window.frame
        // NSWindow frames are bottom-left based. Leaving the origin's x alone
        // holds the left edge, the one the sidebar is anchored to, while the y
        // has to fall by the height change, or the window would grow upward off
        // the top of the screen instead of downward from its title bar.
        frame.origin.y -= target.height - current.height
        frame.size = target

        // `setFrame(animate:)` runs a blocking animation on AppKit's own timing,
        // which neither matches the content's curve nor lets the run loop
        // service it. The animator proxy is asynchronous and takes a curve.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            // Decelerating, like the spring it is travelling with.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            guard let window = self?.window else { return }
            // Pin it shut again at the size it landed on.
            window.minSize = target
            window.maxSize = target
        }
    }

    /// Seat the window controls inside the floating sidebar.
    private func placeWindowControls() {
        guard let window else { return }
        for type in Self.controlTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            let origin = controlOrigins[type] ?? button.frame.origin
            controlOrigins[type] = origin
            // The titlebar container is not flipped, so down is -y.
            button.setFrameOrigin(NSPoint(x: origin.x + Self.controlOffset.dx,
                                          y: origin.y - Self.controlOffset.dy))
        }
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }
}
