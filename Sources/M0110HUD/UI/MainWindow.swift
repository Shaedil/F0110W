import AppKit
import QuartzCore
import SwiftUI

/// The sidebar sets the window width and the keycode picker sets its height.
struct WindowLayout: Equatable {
    var sidebarVisible: Bool
    var pickerOpen: Bool
}

/// Hosts `RootView`. Separate from the HUD so the app can run as a menu bar
/// agent with no window.
final class MainWindowController: NSObject, NSWindowDelegate {
    /// Lets the app go back to a menu bar agent with no Dock icon.
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) { onClose?() }

    private var fullScreen = false
    private var layout = WindowLayout(sidebarVisible: true, pickerOpen: false)

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreen = true
        // A non-resizable window goes full screen at its own size, centered in black.
        window?.styleMask.insert(.resizable)
        window?.minSize = Self.size(for: layout)
        window?.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                 height: CGFloat.greatestFiniteMagnitude)
    }

    func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
        proposedSize
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreen = false
        window?.styleMask.remove(.resizable)
        let target = Self.size(for: layout)
        window?.minSize = target
        window?.maxSize = target
        if let window, window.frame.size != target {
            // Exiting restores the old frame, which is wrong if the sidebar or
            // picker changed meanwhile.
            var frame = window.frame
            frame.origin.y += frame.height - target.height
            frame.size = target
            window.setFrame(frame, display: true)
        }
    }

    /// The window is not resizable by hand. Each dimension has two sizes, set by
    /// the sidebar and the picker, so the board always stays the same size.

    /// Sidebar plus the board panel at the board's maximum size, with padding.
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

    /// Moves the window controls in from AppKit's spot, which sits on the
    /// floating sidebar's rounded edge.
    private static let controlOffset = CGVector(dx: 11, dy: 9)
    /// Center of the window controls from the top edge, used by `RootView` to
    /// line up the sidebar toggle. AppKit's 16 pt and 69 pt were measured on
    /// the running window.
    static var controlCentreY: CGFloat { 16 + controlOffset.dy }
    static var controlsTrailingX: CGFloat { 69 + controlOffset.dx }
    private static let controlTypes: [NSWindow.ButtonType] =
        [.closeButton, .miniaturizeButton, .zoomButton]

    /// AppKit's original button positions, so repeated nudges do not add up.
    private var controlOrigins: [NSWindow.ButtonType: NSPoint] = [:]
    private var resizeObserver: NSObjectProtocol?

    private var window: NSWindow?
    private let controller: KeyboardController
    private let initialPane: Pane
    private let onPaneChange: ((Pane) -> Void)?

    init(controller: KeyboardController, initialPane: Pane = .keys,
         onPaneChange: ((Pane) -> Void)? = nil) {
        self.controller = controller
        self.initialPane = initialPane
        self.onPaneChange = onPaneChange
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
                         // No `.resizable`, or the window shows a resize cursor
                         // and zoom button that do nothing.
                         styleMask: [.titled, .closable, .miniaturizable,
                                     .fullSizeContentView],
                         backing: .buffered,
                         defer: false)
        window = w
        w.contentView = NSHostingView(rootView: RootView(
            controller: controller,
            initialPane: initialPane,
            onPaneChange: onPaneChange,
            onLayoutChange: { [weak self] layout in
                MainActor.assumeIsolated { self?.resize(to: layout) }
            }))
        w.title = "M0110"
        // Always dark, sidebar included, whatever the system setting is.
        w.appearance = NSAppearance(named: .darkAqua)
        // The theme paints its own background under the title bar.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // Otherwise dragging a slider also moves the window.
        w.isMovableByWindowBackground = false
        // Pinning both bounds also keeps a restored frame, zoom or Stage
        // Manager tile at this size.
        w.minSize = opening
        w.maxSize = opening
        w.center()
        w.isReleasedWhenClosed = false
        // The green button goes full screen, since zoom does nothing at a
        // pinned size.
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self

        placeWindowControls()
        // AppKit moves the buttons back on every resize.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeWindowControls() }
            }

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// About the `response` of the sidebar's SwiftUI spring, so the window edge
    /// moves with it.
    private static let resizeDuration: TimeInterval = 0.34

    private func resize(to layout: WindowLayout) {
        self.layout = layout
        guard let window, !fullScreen else { return }
        let target = Self.size(for: layout)
        let current = window.frame.size
        guard abs(current.width - target.width) > 0.5
                || abs(current.height - target.height) > 0.5 else { return }

        // Widen the pinned bounds first. `setFrame` clamps to them, so pinned
        // bounds turn the animation into a jump.
        window.minSize = NSSize(width: min(current.width, target.width),
                                height: min(current.height, target.height))
        window.maxSize = NSSize(width: max(current.width, target.width),
                                height: max(current.height, target.height))

        var frame = window.frame
        // Frames are bottom-left based. Keep x so the left edge holds, and move
        // y so the window grows down from its title bar.
        frame.origin.y -= target.height - current.height
        frame.size = target

        // `setFrame(animate:)` blocks and uses AppKit's own timing. The animator
        // proxy is async and takes a curve.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            // Ease-out, to match the sidebar's spring.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            guard let window = self?.window else { return }
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
            // The nudge pushes the buttons past the titlebar view's bounds, so
            // turn off clipping on every view up the chain.
            var ancestor: NSView? = button.superview
            while let view = ancestor, view !== window.contentView?.superview {
                view.clipsToBounds = false
                ancestor = view.superview
            }
        }
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }
}
