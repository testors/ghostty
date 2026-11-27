import AppKit

extension TerminalController {
    /// Arranges the terminal windows on `screen` in a grid that fills its
    /// visible frame (the screen without the menu bar and Dock), with `gap`
    /// points between the windows and around the edges. See `WindowGrid` for
    /// how the grid is chosen. This is the `tile_windows` keybind action.
    ///
    /// Hidden, minimized, and fullscreen windows and windows on other Spaces
    /// are left alone. The tabs of a window share its frame, so a window with
    /// tabs is one window in the grid.
    static func tileWindows(on screen: NSScreen, gap: CGFloat) {
        let windows: [NSWindow] = all.compactMap { controller in
            guard let window = controller.window,
                  window.isVisible,
                  !window.isMiniaturized,
                  window.isOnActiveSpace,
                  window.screen?.displayID == screen.displayID,
                  !window.styleMask.contains(.fullScreen),
                  !(controller.fullscreenStyle?.isFullscreen ?? false) else { return nil }
            if let selected = window.tabGroup?.selectedWindow, selected !== window { return nil }
            return window
        }
        guard !windows.isEmpty else { return }

        let area = screen.visibleFrame
        let grid = WindowGrid(count: windows.count, size: area.size, gap: gap)
        let ordered = grid.order(windows, by: \.frame)
        for (window, frame) in zip(ordered, grid.frames(in: area, gap: gap)) {
            window.setFrame(frame, display: true)

            // Other apps' windows may cover some of the grid.
            window.orderFront(nil)
        }
    }
}
