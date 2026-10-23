import AppKit

/// A drop target shown in titlebar and tab accessories only during a surface drag.
final class TerminalTabDropView: NSView {
    private static let targetSize = NSSize(width: 100, height: 24)

    private weak var targetWindow: TerminalWindow?
    weak var surface: Ghostty.SurfaceView? {
        didSet {
            isHighlighted = false
            isHidden = surface == nil
            setAccessibilityElement(surface != nil)
            frame.size = intrinsicContentSize
            invalidateIntrinsicContentSize()
        }
    }

    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    init(targetWindow: TerminalWindow) {
        self.targetWindow = targetWindow
        super.init(frame: .zero)
        isHidden = true
        registerForDraggedTypes([.ghosttySurfaceId])
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Move Terminal to New Tab")
        toolTip = "Drop a terminal here to move it to a new tab"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        surface == nil ? .zero : Self.targetSize
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(
            x: 3,
            y: (bounds.height - Self.targetSize.height) / 2 + 2,
            width: bounds.width - 6,
            height: Self.targetSize.height - 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.3 : 0.12).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        let title = String(localized: "New Tab") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                   withAttributes: attributes)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isHighlighted = accepts(sender)
        return isHighlighted ? .move : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isHighlighted = false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        accepts(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { isHighlighted = false }
        guard accepts(sender), let surface else { return false }
        return targetWindow?.terminalController?.moveSurfaceToTab(surface) ?? false
    }

    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.move),
              let surface,
              Ghostty.SurfaceDragSource.surface(from: sender) === surface else { return false }
        return targetWindow?.terminalController?.canMoveSurfaceToTab(surface) ?? false
    }
}
