import AppKit
import ScreenCaptureKit

class SnipManager: NSObject {
    static let shared = SnipManager()

    private weak var appState: AppState?
    private var selectionManager: SelectionManager?
    private var pinnedWindows: [SnipPinnedWindow] = []

    private override init() {}

    func setup(appState: AppState) {
        self.appState = appState
    }

    func startCapture() {
        checkPermission { [weak self] in
            DispatchQueue.main.async { self?.showSelectionUI() }
        }
    }

    func startPinCapture() {
        startCapture()
    }

    private func checkPermission(then: @escaping () -> Void) {
        if appState?.hasScreenCapturePermission == true {
            then()
            return
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
        alert.informativeText = "截图功能需要屏幕录制权限才能捕获屏幕内容。"
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

    private func showSelectionUI() {
        selectionManager?.dismiss()
        let mgr = SelectionManager()
        selectionManager = mgr
        mgr.show(
            onSelect: { [weak self] rect, screen in
                self?.capture(localRect: rect, screen: screen)
            },
            onCancel: { [weak self] in
                self?.selectionManager = nil
            }
        )
    }

    private func capture(localRect: NSRect, screen: NSScreen) {
        selectionManager = nil

        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID(truncating: $0) } ?? CGMainDisplayID()

        let pointSize = NSSize(width: max(1, localRect.width), height: max(1, localRect.height))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard let display = content.displays.first(where: { $0.displayID == displayID })
                            ?? content.displays.first else {
                        logError("SnipManager", "No display found for displayID \(displayID)")
                        return
                    }

                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.showsCursor = false

                    // Selection rect is screen-local (origin bottom-left); sourceRect uses top-left origin.
                    let sourceRect = CGRect(
                        x: localRect.origin.x,
                        y: max(0, screen.frame.height - localRect.maxY),
                        width: localRect.width,
                        height: localRect.height
                    )
                    let scale = max(1, screen.backingScaleFactor)
                    config.sourceRect = sourceRect
                    config.width = max(1, Int((sourceRect.width * scale).rounded()))
                    config.height = max(1, Int((sourceRect.height * scale).rounded()))

                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

                    self.pinImage(image, pointSize: pointSize)
                } catch {
                    logError("SnipManager", "Screen capture failed: \(error)")
                }
            }
        }
    }

    private func pinImage(_ image: CGImage, pointSize: NSSize) {
        let pinned = SnipPinnedWindow(image: image, pointSize: pointSize) { [weak self] win in
            self?.pinnedWindows.removeAll(where: { $0 === win })
        }
        pinnedWindows.append(pinned)
        pinned.show()
    }
}

private final class SnipPinnedKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SnipPinnedWindow {
    private let window: NSWindow
    private let closeCallback: (SnipPinnedWindow) -> Void

    init(image: CGImage, pointSize: NSSize, onClose: @escaping (SnipPinnedWindow) -> Void) {
        self.closeCallback = onClose
        let imageSize = pointSize
        let maxWidth: CGFloat = 720
        let maxHeight: CGFloat = 520
        let scale = min(1, min(maxWidth / imageSize.width, maxHeight / imageSize.height))
        let displaySize = NSSize(width: max(180, imageSize.width * scale),
                                 height: max(80, imageSize.height * scale))

        window = SnipPinnedKeyWindow(contentRect: NSRect(origin: .zero, size: displaySize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = true
        window.isMovableByWindowBackground = false

        let content = SnipPinnedContentView(frame: NSRect(origin: .zero, size: displaySize),
                                            image: image,
                                            pointSize: pointSize) { [weak self] in
            self?.close()
        }
        window.contentView = content

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.midX - displaySize.width / 2
            let y = sf.midY - displaySize.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window.orderOut(nil)
        closeCallback(self)
    }
}

private final class SnipPinnedContentView: NSView {
    private let closeAction: () -> Void
    private let baseImage: NSImage
    private let annotationOverlay = SnipAnnotationOverlayView(frame: .zero)
    private let closeBtn = NSButton(title: "X", target: nil, action: nil)
    private let boxBtn = NSButton(title: "Box", target: nil, action: nil)
    private let clearBtn = NSButton(title: "Clear", target: nil, action: nil)
    private let copyBtn = NSButton(title: "Copy", target: nil, action: nil)
    private var isBoxMode = false {
        didSet { updateBoxModeUI() }
    }

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, image: CGImage, pointSize: NSSize, onClose: @escaping () -> Void) {
        self.closeAction = onClose
        self.baseImage = NSImage(cgImage: image, size: pointSize)
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.20).cgColor

        let imageView = NSImageView(frame: bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.image = baseImage
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView)

        annotationOverlay.frame = bounds
        annotationOverlay.autoresizingMask = [.width, .height]
        annotationOverlay.onEnterKey = { [weak self] in
            self?.copyAndClose()
        }
        annotationOverlay.onBoxCommitted = { [weak self] in
            self?.isBoxMode = false
        }
        addSubview(annotationOverlay)

        copyBtn.target = self
        copyBtn.action = #selector(copyTapped)
        styleMiniButton(copyBtn)
        addSubview(copyBtn)

        boxBtn.target = self
        boxBtn.action = #selector(toggleBoxMode)
        styleMiniButton(boxBtn)
        addSubview(boxBtn)

        clearBtn.target = self
        clearBtn.action = #selector(clearBoxes)
        styleMiniButton(clearBtn)
        addSubview(clearBtn)

        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        closeBtn.isBordered = false
        closeBtn.font = .systemFont(ofSize: 11, weight: .bold)
        closeBtn.contentTintColor = .white
        closeBtn.wantsLayer = true
        closeBtn.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        closeBtn.layer?.cornerRadius = 9
        closeBtn.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(closeBtn)

        updateBoxModeUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(annotationOverlay)
    }

    override func layout() {
        super.layout()
        let topY = bounds.height - 24
        closeBtn.frame = NSRect(x: bounds.width - 24, y: topY, width: 18, height: 18)
        boxBtn.frame = NSRect(x: bounds.width - 68, y: topY, width: 40, height: 18)
        clearBtn.frame = NSRect(x: bounds.width - 116, y: topY, width: 44, height: 18)
        copyBtn.frame = NSRect(x: bounds.width - 164, y: topY, width: 44, height: 18)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            copyAndClose()
            return
        }
        super.keyDown(with: event)
    }

    private func styleMiniButton(_ button: NSButton) {
        button.isBordered = false
        button.font = .systemFont(ofSize: 10, weight: .semibold)
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        button.layer?.cornerRadius = 4
        button.autoresizingMask = [.minXMargin, .minYMargin]
    }

    private func updateBoxModeUI() {
        annotationOverlay.isBoxMode = isBoxMode
        if isBoxMode {
            boxBtn.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        } else {
            boxBtn.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        }
    }

    private func copyAnnotatedImageToClipboard() -> Bool {
        let renderSize = NSSize(width: max(1, bounds.width), height: max(1, bounds.height))
        let output = annotationOverlay.annotatedImage(baseImage: baseImage, size: renderSize)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([output]) {
            logInfo("SnipManager", "Pinned image copied to clipboard")
            return true
        } else {
            logError("SnipManager", "Failed to copy pinned image to clipboard")
            return false
        }
    }

    private func copyAndClose() {
        if copyAnnotatedImageToClipboard() {
            closeAction()
        }
    }

    @objc private func copyTapped() {
        copyAndClose()
    }

    @objc private func toggleBoxMode() {
        isBoxMode.toggle()
    }

    @objc private func clearBoxes() {
        annotationOverlay.clearBoxes()
    }

    @objc private func closeTapped() {
        closeAction()
    }
}

private final class SnipAnnotationOverlayView: NSView {
    var isBoxMode = false
    var onEnterKey: (() -> Void)?
    var onBoxCommitted: (() -> Void)?

    private var boxes: [NSRect] = []
    private var drawingStart: NSPoint?
    private var activeBox: NSRect?
    private var dragStartInWindow: NSPoint?
    private var windowStartOrigin: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        strokeBoxes()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        if isBoxMode {
            drawingStart = convert(event.locationInWindow, from: nil)
            activeBox = nil
            needsDisplay = true
            return
        }

        dragStartInWindow = event.locationInWindow
        windowStartOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        if isBoxMode {
            guard let start = drawingStart else { return }
            let current = convert(event.locationInWindow, from: nil)
            activeBox = NSRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            ).intersection(bounds)
            needsDisplay = true
            return
        }

        guard let start = dragStartInWindow,
              let origin = windowStartOrigin,
              let window else { return }
        let current = event.locationInWindow
        let dx = current.x - start.x
        let dy = current.y - start.y
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if isBoxMode {
            if let activeBox, activeBox.width > 4, activeBox.height > 4 {
                boxes.append(activeBox)
            }
            drawingStart = nil
            activeBox = nil
            needsDisplay = true
            onBoxCommitted?()
            return
        }

        dragStartInWindow = nil
        windowStartOrigin = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onEnterKey?()
            return
        }
        super.keyDown(with: event)
    }

    func clearBoxes() {
        boxes.removeAll()
        activeBox = nil
        needsDisplay = true
    }

    func annotatedImage(baseImage: NSImage, size: NSSize) -> NSImage {
        let output = NSImage(size: size)
        output.lockFocus()
        baseImage.draw(in: NSRect(origin: .zero, size: size))
        strokeBoxes()
        output.unlockFocus()
        return output
    }

    private func strokeBoxes() {
        NSColor.systemRed.setStroke()

        for box in boxes {
            let path = NSBezierPath(rect: box)
            path.lineWidth = 2
            path.stroke()
        }

        if let activeBox {
            let path = NSBezierPath(rect: activeBox)
            path.lineWidth = 2
            path.stroke()
        }
    }
}
