import AppKit

/// Floating bilingual transcript window.
/// Accumulates EN+ZH entries, auto-scrolls, groups entries into paragraphs on silence gaps.
class TranscriptOverlay {

    private let windowWidth: CGFloat = 500
    private let windowHeight: CGFloat = 380
    private let headerHeight: CGFloat = 36

    private var window: NSWindow?
    private var textView: NSTextView?

    // MARK: - Public API

    func appendEntry(english: String, chinese: String, newParagraph: Bool) {
        guard !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async { self._append(english: english, chinese: chinese, newParagraph: newParagraph) }
    }

    func clear() {
        DispatchQueue.main.async {
            self.textView?.textStorage?.setAttributedString(NSAttributedString(string: ""))
        }
    }

    func hide() {
        DispatchQueue.main.async { self.window?.orderOut(nil) }
    }

    // MARK: - Private

    private func _append(english: String, chinese: String, newParagraph: Bool) {
        if window == nil { createWindow() }
        guard let storage = textView?.textStorage else { return }

        let chunk = NSMutableAttributedString()

        if newParagraph && storage.length > 0 {
            chunk.append(attr("\n", color: .clear, size: 6))
        }

        chunk.append(attr(english + "\n", color: .white, size: 14, weight: .regular))

        if !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunk.append(attr(chinese + "\n", color: NSColor(white: 0.65, alpha: 1), size: 13, weight: .regular))
        }

        storage.append(chunk)
        textView?.scrollToEndOfDocument(nil)
        window?.orderFrontRegardless()
    }

    private func attr(_ string: String, color: NSColor, size: CGFloat, weight: NSFont.Weight = .regular) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: size, weight: weight),
        ])
    }

    private func createWindow() {
        let size = CGSize(width: windowWidth, height: windowHeight)
        let origin: NSPoint
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            origin = NSPoint(x: sf.maxX - windowWidth - 20, y: sf.maxY - windowHeight - 20)
        } else {
            origin = .zero
        }

        let w = NSWindow(contentRect: NSRect(origin: origin, size: size),
                         styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        w.hasShadow = true
        w.ignoresMouseEvents = false
        w.minSize = NSSize(width: 280, height: 160)

        // Container — fills content view and resizes with it
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        // Header — full width, pinned to top
        let header = NSView(frame: NSRect(x: 0, y: windowHeight - headerHeight,
                                          width: windowWidth, height: headerHeight))
        header.autoresizingMask = [.width, .minYMargin]
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor

        let titleLabel = NSTextField(labelWithString: "Live Transcript")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.65, alpha: 1)
        titleLabel.frame = NSRect(x: 12, y: 10, width: 160, height: 16)
        header.addSubview(titleLabel)

        let clearBtn = NSButton(title: "清除", target: self, action: #selector(clearButtonClicked))
        clearBtn.isBordered = false
        clearBtn.font = .systemFont(ofSize: 11)
        clearBtn.contentTintColor = NSColor(white: 0.45, alpha: 1)
        clearBtn.frame = NSRect(x: windowWidth - 52, y: 8, width: 40, height: 20)
        clearBtn.autoresizingMask = [.minXMargin]
        header.addSubview(clearBtn)

        container.addSubview(header)

        // Scroll view — fills space below header, resizes with window
        let scrollRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight - headerHeight)
        let scrollView = NSScrollView(frame: scrollRect)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight - headerHeight))
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]

        scrollView.documentView = tv
        container.addSubview(scrollView)

        w.contentView = container
        self.window = w
        self.textView = tv

        logInfo("TranscriptOverlay", "Created \(Int(windowWidth))×\(Int(windowHeight))pt")
    }

    @objc private func clearButtonClicked() {
        clear()
    }
}
