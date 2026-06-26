import AppKit
import Vision
import ScreenCaptureKit

// MARK: - OCRManager

class OCRManager: NSObject {
    static let shared = OCRManager()

    private weak var appState: AppState?
    private var selectionManager: SelectionManager?
    private var resultOverlay: OCRResultOverlay?

    private override init() {}

    func setup(appState: AppState) {
        self.appState = appState
    }

    func startCapture() {
        checkPermission { [weak self] in
            DispatchQueue.main.async { self?.showSelectionUI() }
        }
    }

    // MARK: - Permission

    private func checkPermission(then: @escaping () -> Void) {
        if appState?.hasScreenCapturePermission == true {
            then(); return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] _, error in
            DispatchQueue.main.async {
                if error != nil {
                    self?.appState?.hasScreenCapturePermission = false
                    self?.showPermissionAlert()
                } else {
                    self?.appState?.hasScreenCapturePermission = true
                    then()
                }
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "OCR 截图功能需要屏幕录制权限才能捕获屏幕内容。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }
    }

    // MARK: - Selection UI

    private func showSelectionUI() {
        selectionManager?.dismiss()
        let mgr = SelectionManager()
        selectionManager = mgr
        mgr.show(
            onSelect: { [weak self] rect, screen in
                self?.captureAndOCR(localRect: rect, screen: screen)
            },
            onCancel: { [weak self] in
                self?.selectionManager = nil
            }
        )
    }

    // MARK: - Capture & OCR

    private func captureAndOCR(localRect: NSRect, screen: NSScreen) {
        selectionManager = nil

        // Convert local view coords → global NS coords → CG coords
        let globalNS = NSRect(
            origin: CGPoint(x: screen.frame.origin.x + localRect.origin.x,
                            y: screen.frame.origin.y + localRect.origin.y),
            size: localRect.size
        )
        let primaryH = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? screen.frame.height
        let cgRect = CGRect(x: globalNS.origin.x,
                            y: primaryH - globalNS.maxY,
                            width: globalNS.width,
                            height: globalNS.height)

        // Wait one runloop so the overlay windows finish closing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            // Find which display contains the selection rect
            var displayID = CGMainDisplayID()
            var displayCount: UInt32 = 0
            CGGetDisplaysWithRect(cgRect, 1, &displayID, &displayCount)
            if displayCount == 0 { displayID = CGMainDisplayID() }

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    // Capture the full display via SCScreenshotManager (CGDisplayCreateImage removed in macOS 15)
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard let display = content.displays.first(where: { $0.displayID == displayID })
                            ?? content.displays.first else {
                        logError("OCRManager", "No display found for displayID \(displayID)")
                        return
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.showsCursor = false
                    let fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

                    // Convert global CG rect (top-left origin, Y downward) to display-local pixel coords.
                    // CGImage.cropping(to:) uses bottom-left origin, so we flip Y.
                    let displayBounds = CGDisplayBounds(displayID)
                    let scaleX = CGFloat(fullImage.width) / displayBounds.width
                    let scaleY = CGFloat(fullImage.height) / displayBounds.height
                    let localPtX = cgRect.origin.x - displayBounds.origin.x
                    let localPtY = cgRect.origin.y - displayBounds.origin.y
                    let pixX = localPtX * scaleX
                    let pixY = localPtY * scaleY
                    let pixW = cgRect.width * scaleX
                    let pixH = cgRect.height * scaleY
                    // Flip Y: CGImage row-0 is top of display; cropping coordinate origin is bottom-left
                    let cropRect = CGRect(x: pixX, y: CGFloat(fullImage.height) - pixY - pixH,
                                          width: pixW, height: pixH)

                    guard let image = fullImage.cropping(to: cropRect) else {
                        logError("OCRManager", "Failed to crop image to \(cropRect)")
                        return
                    }
                    self.runOCR(image: image)
                } catch {
                    logError("OCRManager", "Screen capture failed: \(error)")
                }
            }
        }
    }

    private func runOCR(image: CGImage) {
        let mouseLocation = NSEvent.mouseLocation

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var recognizedText = ""

            let request = VNRecognizeTextRequest { req, _ in
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                recognizedText = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                logError("OCRManager", "VNImageRequestHandler failed: \(error)")
            }

            let result = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            logInfo("OCRManager", "OCR result: \(result.prefix(80))")

            DispatchQueue.main.async { [weak self] in
                if result.isEmpty {
                    self?.appState?.showError("OCR 未识别到文字")
                } else {
                    self?.showResult(result, near: mouseLocation)
                }
            }
        }
    }

    private func showResult(_ text: String, near point: NSPoint) {
        resultOverlay?.dismiss()
        let overlay = OCRResultOverlay()
        resultOverlay = overlay
        overlay.show(text: text, near: point)
    }
}

// MARK: - OCRResultOverlay

class OCRResultOverlay: NSObject {

    private let windowWidth: CGFloat = 440
    private let windowHeight: CGFloat = 200
    private let headerHeight: CGFloat = 32

    private var window: NSWindow?
    private var textView: NSTextView?
    private var escMonitor: Any?
    private var clickMonitor: Any?
    private var dismissWork: DispatchWorkItem?
    private var currentContent = ""

    func show(text: String, near point: NSPoint) {
        currentContent = text

        let size = CGSize(width: windowWidth, height: windowHeight)
        let origin = clampedOrigin(near: point, size: size)

        let w = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        w.hasShadow = true
        w.ignoresMouseEvents = false

        let (container, tv) = buildContent()
        w.contentView = container
        self.window = w
        self.textView = tv

        // Populate text
        let attr = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 14, weight: .regular)
        ])
        tv.textStorage?.setAttributedString(attr)
        tv.scrollToBeginningOfDocument(nil)

        w.orderFrontRegardless()
        registerMonitors()
        scheduleAutoDismiss(seconds: 30)
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        window?.orderOut(nil)
        window = nil
        textView = nil
        currentContent = ""
    }

    // MARK: - Layout

    private func buildContent() -> (NSView, NSTextView) {
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

        let titleLabel = NSTextField(labelWithString: "OCR 结果")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor(white: 0.70, alpha: 1)
        titleLabel.frame = NSRect(x: 12, y: 8, width: 120, height: 18)
        header.addSubview(titleLabel)

        let pasteBtn = NSButton(title: "粘贴", target: self, action: #selector(pasteTapped))
        pasteBtn.isBordered = false
        pasteBtn.font = .systemFont(ofSize: 11, weight: .medium)
        pasteBtn.contentTintColor = .white
        pasteBtn.frame = NSRect(x: windowWidth - 68, y: 7, width: 40, height: 18)
        header.addSubview(pasteBtn)

        let closeBtn = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        closeBtn.isBordered = false
        closeBtn.font = .systemFont(ofSize: 11)
        closeBtn.contentTintColor = NSColor(white: 0.45, alpha: 1)
        closeBtn.frame = NSRect(x: windowWidth - 26, y: 7, width: 18, height: 18)
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
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]

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

    // MARK: - Monitors

    private func registerMonitors() {
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, let w = self.window else { return }
            if !w.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
        }
    }

    private func scheduleAutoDismiss(seconds: Double) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func pasteTapped() {
        guard !currentContent.isEmpty else { return }
        TextPaster.shared.pasteText(currentContent)
        dismiss()
    }

    @objc private func closeTapped() { dismiss() }
}
