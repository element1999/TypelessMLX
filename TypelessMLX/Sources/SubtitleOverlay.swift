import AppKit

/// Real-time bilingual subtitle pill at bottom-center of screen.
/// Shows streaming English (partial) and async Chinese translation.
class SubtitleOverlay {

    private let overlayWidth: CGFloat = 820
    private let overlayHeight: CGFloat = 140
    private let cornerRadius: CGFloat = 14

    private var window: NSWindow?
    private var prevEnglishLabel: NSTextField?
    private var prevChineseLabel: NSTextField?
    private var currEnglishLabel: NSTextField?
    private var currChineseLabel: NSTextField?
    private var hideTimer: Timer?

    private var prevEnglish: String = ""
    private var prevChinese: String = ""
    private var currChinese: String = ""

    // MARK: - Public API

    /// Update the live streaming English line (called ~every 300ms while speaking).
    func updatePartialEnglish(_ text: String) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            if self.window == nil { self.createWindow() }
            self.currEnglishLabel?.stringValue = text
            self.show()
        }
    }

    /// Chinese translation arrived — append below current English.
    func updateChineseTranslation(_ text: String) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            self.currChinese = text
            self.currChineseLabel?.stringValue = text
            self.show()
        }
    }

    /// Called on session restart: push current text to history row, clear current.
    func advanceToHistory(english: String, chinese: String) {
        DispatchQueue.main.async {
            self.prevEnglish = english
            self.prevChinese = chinese
            self.currChinese = ""
            self.prevEnglishLabel?.stringValue = english
            self.prevChineseLabel?.stringValue = chinese
            self.currEnglishLabel?.stringValue = ""
            self.currChineseLabel?.stringValue = ""
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

    private func show() {
        window?.alphaValue = 1.0
        window?.orderFrontRegardless()
        resetHideTimer()
    }

    private func resetHideTimer() {
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
            self?.prevEnglish = ""
            self?.prevChinese = ""
            self?.currChinese = ""
            self?.prevEnglishLabel?.stringValue = ""
            self?.prevChineseLabel?.stringValue = ""
            self?.currEnglishLabel?.stringValue = ""
            self?.currChineseLabel?.stringValue = ""
        })
    }

    private func createWindow() {
        let size = CGSize(width: overlayWidth, height: overlayHeight)

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = false
        w.hasShadow = true
        w.ignoresMouseEvents = true

        let pill = NSView(frame: NSRect(origin: .zero, size: size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        pill.layer?.cornerRadius = cornerRadius
        pill.layer?.masksToBounds = true

        // Previous English — top row, dimmed small
        let pEng = label(font: .systemFont(ofSize: 13), color: NSColor(white: 0.52, alpha: 1.0))
        pEng.frame = CGRect(x: 16, y: 106, width: overlayWidth - 32, height: 20)
        pill.addSubview(pEng)
        prevEnglishLabel = pEng

        // Previous Chinese — second row, dimmed accent
        let pChi = label(font: .systemFont(ofSize: 12), color: NSColor(white: 0.42, alpha: 1.0))
        pChi.frame = CGRect(x: 16, y: 84, width: overlayWidth - 32, height: 18)
        pill.addSubview(pChi)
        prevChineseLabel = pChi

        // Current English — large bright
        let cEng = label(font: .systemFont(ofSize: 19, weight: .medium), color: .white)
        cEng.frame = CGRect(x: 16, y: 46, width: overlayWidth - 32, height: 26)
        pill.addSubview(cEng)
        currEnglishLabel = cEng

        // Current Chinese — accent blue
        let cChi = label(font: .systemFont(ofSize: 15), color: NSColor(red: 0.48, green: 0.82, blue: 1.0, alpha: 0.92))
        cChi.frame = CGRect(x: 16, y: 16, width: overlayWidth - 32, height: 22)
        pill.addSubview(cChi)
        currChineseLabel = cChi

        w.contentView = pill

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: sf.midX - overlayWidth / 2, y: sf.minY + 160))
        }

        self.window = w
        logInfo("SubtitleOverlay", "Created \(Int(overlayWidth))×\(Int(overlayHeight))pt")
    }

    private func label(font: NSFont, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = font
        f.textColor = color
        f.backgroundColor = .clear
        f.isBezeled = false
        f.isEditable = false
        f.alignment = .center
        f.lineBreakMode = .byTruncatingTail
        return f
    }
}
