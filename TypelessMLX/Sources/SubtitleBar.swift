import AppKit

/// Bottom-center subtitle overlay — shows at most 2 lines (English + Chinese).
/// New content replaces old; auto-hides after silence.
class SubtitleBar: NSObject {
    static let shared = SubtitleBar()

    private var window: NSWindow?
    private var englishLabel: NSTextField?
    private var chineseLabel: NSTextField?
    private var hideWork: DispatchWorkItem?

    private static let maxWidthFraction: CGFloat = 0.70
    private static let lineHeight: CGFloat = 30
    private static let vertPad: CGFloat = 10
    private static let horizPad: CGFloat = 24
    private static let bottomOffset: CGFloat = 80   // above dock
    private static let cornerRadius: CGFloat = 8
    private static let autoHideDelay: TimeInterval = 6

    private override init() { super.init() }

    // MARK: - Public API

    /// Show growing partial text (English only, dimmed).
    func updateLive(_ english: String) {
        guard !english.isEmpty else { return }
        DispatchQueue.main.async {
            self.ensureWindow()
            self.englishLabel?.attributedStringValue = self.outlined(english, size: 17, weight: .semibold,
                                                                      color: NSColor(white: 0.80, alpha: 1))
            self.chineseLabel?.attributedStringValue = NSAttributedString(string: "")
            self.scheduleHide()
            self.window?.orderFrontRegardless()
        }
    }

    /// Show a committed sentence with its translation (bright white + yellow).
    func commitSentence(english: String, chinese: String) {
        guard !english.isEmpty else { return }
        DispatchQueue.main.async {
            self.ensureWindow()
            self.englishLabel?.attributedStringValue = self.outlined(english, size: 17, weight: .bold,
                                                                      color: .white)
            self.chineseLabel?.attributedStringValue = self.outlined(chinese, size: 15, weight: .medium,
                                                                      color: NSColor(red: 1, green: 0.95, blue: 0.55, alpha: 1))
            self.scheduleHide()
            self.window?.orderFrontRegardless()
        }
    }

    private func outlined(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .strokeColor: NSColor(white: 0, alpha: 0.95),
            .strokeWidth: -3.5,
            .font: NSFont.systemFont(ofSize: size, weight: weight),
        ])
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        DispatchQueue.main.async { self.window?.orderOut(nil) }
    }

    // MARK: - Private

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHideDelay, execute: work)
    }

    private func ensureWindow() {
        if window != nil { return }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.visibleFrame

        let w = min(sf.width * Self.maxWidthFraction, 920)
        let h = Self.lineHeight * 2 + Self.vertPad * 3
        let x = sf.minX + (sf.width - w) / 2
        let y = sf.minY + Self.bottomOffset

        let win = NSWindow(
            contentRect: NSRect(x: x, y: y, width: w, height: h),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true
        win.hasShadow = false

        let container = NSView(frame: NSRect(origin: .zero, size: CGSize(width: w, height: h)))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.cornerRadius = Self.cornerRadius

        let enLabel = makeLabel(size: 17, weight: .semibold, color: .white)
        enLabel.frame = NSRect(x: Self.horizPad,
                               y: Self.vertPad + Self.lineHeight,
                               width: w - Self.horizPad * 2,
                               height: Self.lineHeight)

        let zhLabel = makeLabel(size: 15, weight: .regular,
                                color: NSColor(red: 1, green: 0.95, blue: 0.55, alpha: 1))
        zhLabel.frame = NSRect(x: Self.horizPad,
                               y: Self.vertPad,
                               width: w - Self.horizPad * 2,
                               height: Self.lineHeight)

        container.addSubview(enLabel)
        container.addSubview(zhLabel)
        win.contentView = container

        self.window = win
        self.englishLabel = enLabel
        self.chineseLabel = zhLabel
    }

    private func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.alignment = .center
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        f.isBezeled = false
        f.drawsBackground = false
        return f
    }
}
