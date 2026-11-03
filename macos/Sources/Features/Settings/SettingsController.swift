import AppKit
import SwiftUI

/// The settings window. There is only one; showing it again brings the
/// existing window forward.
final class SettingsController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsController()

    private var store: SettingsStore?

    /// The smallest size of the window. It is tall enough to show every
    /// page in the sidebar.
    private static let minSize = NSSize(width: 760, height: 540)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.toolbarStyle = .unified
        // This also keeps a smaller saved frame from being restored.
        window.minSize = Self.minSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.identifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.settings")
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("GhosttySettings")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Show the settings window for the given app.
    @MainActor
    func show(app: Ghostty.App) {
        if store == nil {
            let store = SettingsStore(app: app)
            self.store = store
            let host = NSHostingController(rootView: SettingsView(store: store))
            // Keep SwiftUI from sizing the window. It sets the window's
            // minimum size from the content, but measures the sidebar
            // lazily, so the minimum grew after the window was shown and
            // the window grew with it on the next click or focus change.
            // windowWillResize keeps the minimum size instead.
            host.sizingOptions = []
            if let window {
                // Setting the content view controller resizes the window to
                // the view's size, which is empty here. Keep the frame.
                host.view.setFrameSize(window.contentRect(forFrameRect: window.frame).size)
                window.contentViewController = host
            }
        } else {
            store?.reloadFromDisk()
        }

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: First Responder

    @IBAction func close(_ sender: Any) {
        window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any) {
        window?.performClose(sender)
    }

    /// This is called when "escape" is pressed.
    @objc func cancel(_ sender: Any?) {
        close(sender)
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        MainActor.assumeIsolated { store?.undoManager }
    }

    /// Keeps the minimum size, which SwiftUI clears. See show(app:).
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, Self.minSize.width),
            height: max(frameSize.height, Self.minSize.height)
        )
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Drop the editor and file watchers until the window opens again.
            store?.close()
            store = nil
            window?.contentViewController = nil
        }
    }
}
