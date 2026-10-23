import AppKit
import SwiftUI

/// The settings window. There is only one; showing it again brings the
/// existing window forward.
final class SettingsController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsController()

    private var store: SettingsStore?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 480)
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
            window?.contentViewController = host
        } else {
            store?.reloadFromDisk()
        }

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        MainActor.assumeIsolated { store?.undoManager }
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
