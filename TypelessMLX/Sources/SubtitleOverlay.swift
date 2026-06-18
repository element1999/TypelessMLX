import AppKit

/// Floating subtitle overlay for meeting mode.
/// Two-line dark pill at bottom-center: previous sentence (dimmed) above current sentence (bright).
class SubtitleOverlay {

    private let overlayWidth: CGFloat = 700
    private let overlayHeight: CGFloat = 90
    private let cornerRadius: CGFloat = 14

    private var window: NSWindow?
    private var currentLabel: NSTextField?
    private var previousLabel: NSTextField?
    private var hideTimer: Timer?
    private var currentText: String = ""

    // MARK: - Public API

    func updateSubtitle(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async { self._updateSubtitle(text) }
    }

    func keepAlive() {
        DispatchQueue.main.async {
            if self.window?.isVisible == true {
                self.hideTimer?.invalidate()
                self.hideTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
                    self?.fadeAndHide()
                }
            } else if !self.currentText.isEmpty {
                // Window was hidden due to gap in processing — re-show same text
                self._updateSubtitle(self.currentText)
            }
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.hideTimer?.invalidate()
            self.hideTimer = nil
            self.window?.orderOut(nil)
        }
    }

    // MARK: - Private

    private func _updateSubtitle(_ text: String) {
        if window == nil { createWindow() }

        previousLabel?.stringValue = currentText
        currentText = text
        currentLabel?.stringValue = text

        window?.alphaValue = 1.0
        window?.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            self?.fadeAndHide()
        }
    }

    private func fadeAndHide() {
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 1.0
            win.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            win.orderOut(nil)
            win.alphaValue = 1.0
            self?.previousLabel?.stringValue = ""
            self?.currentText = ""
            self?.currentLabel?.stringValue = ""
        })
    }

    private func createWindow() {
        let size = CGSize(width: overlayWidth, height: overlayHeight)
        let rect = NSRect(origin: .zero, size: size)

        let w = NSWindow(contentRect: rect, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = false
        w.hasShadow = true
        w.ignoresMouseEvents = true

        let pill = NSView(frame: rect)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        pill.layer?.cornerRadius = cornerRadius
        pill.layer?.masksToBounds = true

        let prevLabel = NSTextField(labelWithString: "")
        prevLabel.font = .systemFont(ofSize: 15, weight: .regular)
        prevLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        prevLabel.backgroundColor = .clear
        prevLabel.isBezeled = false
        prevLabel.isEditable = false
        prevLabel.alignment = .center
        prevLabel.lineBreakMode = .byTruncatingTail
        prevLabel.frame = CGRect(x: 16, y: overlayHeight - 38, width: overlayWidth - 32, height: 24)
        pill.addSubview(prevLabel)
        self.previousLabel = prevLabel

        let currLabel = NSTextField(labelWithString: "")
        currLabel.font = .systemFont(ofSize: 19, weight: .medium)
        currLabel.textColor = .white
        currLabel.backgroundColor = .clear
        currLabel.isBezeled = false
        currLabel.isEditable = false
        currLabel.alignment = .center
        currLabel.lineBreakMode = .byTruncatingTail
        currLabel.frame = CGRect(x: 16, y: 10, width: overlayWidth - 32, height: 28)
        pill.addSubview(currLabel)
        self.currentLabel = currLabel

        w.contentView = pill

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            // Position above RecordingOverlay (which sits at minY+80)
            w.setFrameOrigin(NSPoint(x: sf.midX - overlayWidth / 2, y: sf.minY + 160))
        }

        self.window = w
        logInfo("SubtitleOverlay", "Created \(Int(overlayWidth))×\(Int(overlayHeight))pt")
    }
}
