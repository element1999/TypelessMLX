import AppKit

class LookupOverlay: NSObject {

    private let windowWidth: CGFloat = 360
    private let windowHeight: CGFloat = 220
    private let headerHeight: CGFloat = 30

    private var window: NSWindow?
    private var textView: NSTextView?
    private var escMonitor: Any?
    private var clickMonitor: Any?
    private var dismissWork: DispatchWorkItem?

    // MARK: - Public API

    func show(word: String, near point: NSPoint) {
        let size = CGSize(width: windowWidth, height: windowHeight)
        let origin = clampedOrigin(near: point, size: size)

        let w = NSWindow(contentRect: NSRect(origin: origin, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        w.hasShadow = true
        w.ignoresMouseEvents = false

        let (container, tv) = buildContent(word: word)
        w.contentView = container
        self.window = w
        self.textView = tv

        w.orderFrontRegardless()
        registerMonitors()
        scheduleAutoDismiss()
    }

    func setContent(_ text: String) {
        guard let tv = textView else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = trimmed.isEmpty ? "（无结果）" : trimmed
        let attr = NSAttributedString(string: content, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .regular)
        ])
        tv.textStorage?.setAttributedString(attr)
        tv.scrollToBeginningOfDocument(nil)
        // Extend auto-dismiss to 30s once content arrives
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        window?.orderOut(nil)
        window = nil
        textView = nil
    }

    // MARK: - Layout

    private func buildContent(word: String) -> (NSView, NSTextView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        // Header
        let header = NSView(frame: NSRect(x: 0, y: windowHeight - headerHeight,
                                          width: windowWidth, height: headerHeight))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        container.addSubview(header)

        let wordLabel = NSTextField(labelWithString: word)
        wordLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        wordLabel.textColor = .white
        wordLabel.lineBreakMode = .byTruncatingTail
        wordLabel.frame = NSRect(x: 12, y: 7, width: windowWidth - 50, height: 18)
        header.addSubview(wordLabel)

        let closeBtn = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        closeBtn.isBordered = false
        closeBtn.font = .systemFont(ofSize: 11)
        closeBtn.contentTintColor = NSColor(white: 0.45, alpha: 1)
        closeBtn.frame = NSRect(x: windowWidth - 30, y: 6, width: 22, height: 18)
        header.addSubview(closeBtn)

        // Separator
        let sep = NSView(frame: NSRect(x: 0, y: windowHeight - headerHeight - 1, width: windowWidth, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        container.addSubview(sep)

        // Scrollable content
        let contentHeight = windowHeight - headerHeight - 1
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: contentHeight))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: contentHeight))
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]

        let loading = NSAttributedString(string: "查询中…", attributes: [
            .foregroundColor: NSColor(white: 0.45, alpha: 1),
            .font: NSFont.systemFont(ofSize: 13, weight: .regular)
        ])
        tv.textStorage?.setAttributedString(loading)

        scrollView.documentView = tv
        container.addSubview(scrollView)

        return (container, tv)
    }

    // MARK: - Positioning

    private func clampedOrigin(near point: NSPoint, size: CGSize) -> NSPoint {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        let sf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = point.x + 16
        var y = point.y - size.height - 4

        if y < sf.minY { y = point.y + 4 }
        if x + size.width > sf.maxX { x = point.x - size.width - 10 }
        if x < sf.minX { x = sf.minX + 4 }
        if y + size.height > sf.maxY { y = sf.maxY - size.height - 4 }

        return NSPoint(x: x, y: y)
    }

    // MARK: - Monitors & auto-dismiss

    private func registerMonitors() {
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, let w = self.window else { return }
            if !w.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
        }
    }

    private func scheduleAutoDismiss() {
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    @objc private func closeTapped() { dismiss() }
}
