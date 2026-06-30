import AppKit

class SelectionManager: NSObject {
    private var windows: [NSWindow] = []
    private var onSelect: ((NSRect, NSScreen) -> Void)?
    private var onCancel: (() -> Void)?

    func show(onSelect: @escaping (NSRect, NSScreen) -> Void,
              onCancel: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onCancel = onCancel

        for screen in NSScreen.screens {
            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: screen.frame.size),
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .screenSaver
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            win.ignoresMouseEvents = false
            win.isMovable = false
            // Explicitly place each overlay on its target display frame.
            // This avoids coordinate misplacement on extended multi-monitor layouts.
            win.setFrame(screen.frame, display: true)

            let view = SelectionView(frame: win.contentView?.bounds
                                     ?? NSRect(origin: .zero, size: screen.frame.size),
                                     screen: screen)
            view.onSelect = { [weak self] rect in self?.finish(rect: rect, screen: screen) }
            view.onCancel = { [weak self] in self?.cancel() }
            win.contentView = view
            win.makeFirstResponder(view)
            win.orderFrontRegardless()
            windows.append(win)
        }

        NSCursor.crosshair.push()
    }

    func dismiss() {
        NSCursor.pop()
        for win in windows { win.orderOut(nil) }
        windows.removeAll()
        onSelect = nil
        onCancel = nil
    }

    private func finish(rect: NSRect, screen: NSScreen) {
        let callback = onSelect
        dismiss()
        callback?(rect, screen)
    }

    private func cancel() {
        let callback = onCancel
        dismiss()
        callback?()
    }
}

// MARK: - SelectionView

class SelectionView: NSView {
    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private let screen: NSScreen
    private var startPoint: NSPoint?
    private var selectionRect: NSRect?

    private lazy var hintLabel: NSTextField = {
        let f = NSTextField(labelWithString: "拖拽选择区域 · Esc 取消")
        f.font = .systemFont(ofSize: 12)
        f.textColor = NSColor(white: 1, alpha: 0.7)
        f.drawsBackground = false
        f.isBordered = false
        f.isEditable = false
        f.sizeToFit()
        return f
    }()

    init(frame: NSRect, screen: NSScreen) {
        self.screen = screen
        super.init(frame: frame)
        addSubview(hintLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        hintLabel.frame = NSRect(x: 16, y: bounds.height - hintLabel.frame.height - 16,
                                 width: hintLabel.frame.width, height: hintLabel.frame.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dark overlay
        ctx.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.fill(bounds)

        if let r = selectionRect, r.width > 2 && r.height > 2 {
            // Punch through to reveal screen beneath
            ctx.setBlendMode(.clear)
            ctx.fill(r)
            ctx.setBlendMode(.normal)

            // Selection border
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(r)

            // Size label
            let label = String(format: "%.0f × %.0f", r.width, r.height)
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(white: 1, alpha: 0.8),
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            ]
            let attrStr = NSAttributedString(string: label, attributes: attrs)
            let labelSize = attrStr.size()
            var labelOrigin = NSPoint(x: r.maxX - labelSize.width - 4, y: r.minY - labelSize.height - 4)
            if labelOrigin.y < 4 { labelOrigin.y = r.maxY + 4 }
            attrStr.draw(at: labelOrigin)
        }
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selectionRect, rect.width > 4 && rect.height > 4 else {
            startPoint = nil
            selectionRect = nil
            needsDisplay = true
            return
        }
        onSelect?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }
}
