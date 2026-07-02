import AppKit

/// Single-pill floating overlay: gradient bars on top, live text below — all in one white capsule.
/// Pure AppKit, no border, white background, drop shadow.
class RecordingOverlay {

    // MARK: - Layout

    private let overlayWidth:  CGFloat = 520
    private let pillRadius:    CGFloat = 22
    private let barsSectionH:  CGFloat = 58   // pill height when text is hidden
    private let textSectionH:  CGFloat = 84   // extra height added when text is visible
    private let barCount   = 13
    private let barWidth:  CGFloat = 5
    private let barGap:    CGFloat = 3.5
    private let maxBarHeight: CGFloat = 32

    // MARK: - Views & layers

    private var window: NSWindow?
    private var pillView: NSView?
    private var barContainerLayer: CALayer?
    private var barLayers: [CAGradientLayer] = []
    private var textLabel: NSTextField?
    private var hasText = false

    // MARK: - Audio

    private var _currentLevel: Float = 0
    private var levelTimer: Timer?

    // MARK: - Colour themes

    private let recordingColors: [CGColor] = [
        NSColor(red: 0.30, green: 0.50, blue: 1.00, alpha: 1.0).cgColor,
        NSColor(red: 0.72, green: 0.38, blue: 1.00, alpha: 1.0).cgColor,
        NSColor(red: 1.00, green: 0.50, blue: 0.82, alpha: 1.0).cgColor,
    ]
    private let recordingShadow = NSColor(red: 0.55, green: 0.25, blue: 1.0, alpha: 0.55).cgColor

    private let transcribingColors: [CGColor] = [
        NSColor(red: 0.00, green: 0.72, blue: 0.88, alpha: 1.0).cgColor,
        NSColor(red: 0.18, green: 0.42, blue: 1.00, alpha: 1.0).cgColor,
    ]
    private let transcribingShadow = NSColor(red: 0.00, green: 0.60, blue: 1.0, alpha: 0.55).cgColor

    private let transcribingPeakColors: [CGColor] = [
        NSColor(red: 0.45, green: 0.95, blue: 1.00, alpha: 1.0).cgColor,
        NSColor(red: 0.18, green: 0.68, blue: 1.00, alpha: 1.0).cgColor,
    ]

    // MARK: - Public API

    func show(text: String, isRecording: Bool) {
        if window == nil { createWindow() }
        updateBars(isRecording: isRecording)
        window?.orderFrontRegardless()
    }

    func hide() {
        stopAnimation()
        _currentLevel = 0
        window?.orderOut(nil)
    }

    /// Pass an empty string to collapse the text section; non-empty expands the pill.
    func updateLiveText(_ text: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updateLiveText(text)
            }
            return
        }

        guard let label = textLabel, let win = window, let pill = pillView else { return }
        let visibleText = visibleLiveText(from: text)
        if visibleText.isEmpty {
            guard hasText else { return }
            hasText = false
            label.stringValue = ""
            animatePill(expand: false, window: win, pill: pill)
        } else {
            label.stringValue = visibleText
            guard !hasText else { return }
            hasText = true
            animatePill(expand: true, window: win, pill: pill)
        }
    }

    /// Keep a larger recent context window for long partial transcripts.
    private func visibleLiveText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let maxChars = 220
        if trimmed.count <= maxChars { return trimmed }
        return "…" + String(trimmed.suffix(maxChars))
    }

    func updateAudioLevel(_ level: Float) {
        _currentLevel = _currentLevel * 0.65 + level * 0.35
    }

    // MARK: - Pill resize animation

    private func animatePill(expand: Bool, window win: NSWindow, pill: NSView) {
        let delta = textSectionH
        var frame = win.frame
        if expand {
            frame.origin.y -= delta
            frame.size.height += delta
        } else {
            frame.origin.y += delta
            frame.size.height -= delta
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            win.animator().setFrame(frame, display: true)
            pillView?.animator().setFrameSize(NSSize(width: overlayWidth, height: frame.height))
        }

        // Move bar container up/down to stay in the bars section
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        let barContainerY = expand
            ? textSectionH + (barsSectionH - maxBarHeight) / 2
            : (barsSectionH - maxBarHeight) / 2
        barContainerLayer?.frame.origin.y = barContainerY
        CATransaction.commit()

        // Fade text label
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = expand ? 0.18 : 0.12
            textLabel?.animator().alphaValue = expand ? 1.0 : 0.0
        }
    }

    // MARK: - Animation dispatch

    private func updateBars(isRecording: Bool) {
        if isRecording { startWaveAnimation() } else { startTranscribingAnimation() }
    }

    private func applyColors(_ colors: [CGColor], shadow: CGColor) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for bar in barLayers {
            bar.colors      = colors
            bar.shadowColor = shadow
        }
        CATransaction.commit()
    }

    // MARK: - Recording: real audio → CASpringAnimation

    private func startWaveAnimation() {
        stopAnimation()
        applyColors(recordingColors, shadow: recordingShadow)
        _currentLevel = 0
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.applyLevelToBars()
        }
    }

    private func applyLevelToBars() {
        let level     = _currentLevel
        let now       = CACurrentMediaTime()
        let halfCount = Double(barCount - 1) / 2.0

        for (i, bar) in barLayers.enumerated() {
            let phase      = Double(i) / Double(barCount) * 2 * .pi
            let sineWobble = (sin(now * 6.0 + phase) + 1.0) / 2.0
            let centerBias = 1.0 - abs(Double(i) - halfCount) / (halfCount + 1) * 0.35
            let scale = 0.08 + Double(level) * 0.85 * centerBias
                      + sineWobble * max(0.05, Double(level) * 0.18)
            let clamped = max(0.08, min(1.0, scale))

            let spring = CASpringAnimation(keyPath: "transform.scale.y")
            spring.toValue   = NSNumber(value: clamped)
            spring.damping   = 14
            spring.stiffness = 180
            spring.mass      = 1.0
            spring.duration  = min(spring.settlingDuration, 0.45)
            spring.isRemovedOnCompletion = false
            spring.fillMode  = .forwards
            bar.add(spring, forKey: "wave")

            let glowSpring = CASpringAnimation(keyPath: "shadowOpacity")
            glowSpring.toValue   = NSNumber(value: 0.25 + clamped * 0.55)
            glowSpring.damping   = 14
            glowSpring.stiffness = 180
            glowSpring.duration  = min(glowSpring.settlingDuration, 0.45)
            glowSpring.isRemovedOnCompletion = false
            glowSpring.fillMode  = .forwards
            bar.add(glowSpring, forKey: "waveGlow")
        }
    }

    // MARK: - Transcribing: left→right ripple + colour flash

    private func startTranscribingAnimation() {
        stopAnimation()
        applyColors(transcribingColors, shadow: transcribingShadow)

        let now = CACurrentMediaTime()
        for (i, bar) in barLayers.enumerated() {
            let delay = Double(i) / Double(barCount) * 0.65

            let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale.y")
            scaleAnim.values      = [0.10, 0.80, 0.48, 0.22, 0.10] as [NSNumber]
            scaleAnim.keyTimes    = [0.0,  0.18,  0.50, 0.75, 1.0]
            scaleAnim.duration    = 1.5
            scaleAnim.repeatCount = .infinity
            scaleAnim.beginTime   = now + delay
            scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(scaleAnim, forKey: "ripple")

            let glowAnim = CAKeyframeAnimation(keyPath: "shadowOpacity")
            glowAnim.values      = [0.15, 0.90, 0.55, 0.25, 0.15] as [NSNumber]
            glowAnim.keyTimes    = [0.0,  0.18,  0.50, 0.75, 1.0]
            glowAnim.duration    = 1.5
            glowAnim.repeatCount = .infinity
            glowAnim.beginTime   = now + delay
            glowAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(glowAnim, forKey: "rippleGlow")

            let colorAnim = CAKeyframeAnimation(keyPath: "colors")
            colorAnim.values = [
                transcribingColors as NSArray,
                transcribingPeakColors as NSArray,
                transcribingColors as NSArray,
            ]
            colorAnim.keyTimes    = [0.0, 0.18, 1.0]
            colorAnim.duration    = 1.5
            colorAnim.repeatCount = .infinity
            colorAnim.beginTime   = now + delay
            bar.add(colorAnim, forKey: "rippleColor")
        }
    }

    private func stopAnimation() {
        levelTimer?.invalidate()
        levelTimer = nil
        for bar in barLayers { bar.removeAllAnimations() }
    }

    // MARK: - Window creation

    private func createWindow() {
        let initH = barsSectionH
        let size  = CGSize(width: overlayWidth, height: initH)
        let rect  = NSRect(origin: .zero, size: size)

        let w = NSWindow(contentRect: rect, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque   = false
        w.backgroundColor = .clear
        w.level      = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = false
        w.hasShadow  = true
        w.ignoresMouseEvents = true

        // ── White pill (95% opacity) ──────────────────────────────────────────
        let pill = NSView(frame: rect)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        pill.layer?.cornerRadius    = pillRadius
        pill.layer?.masksToBounds   = true
        self.pillView = pill

        guard let pillLayer = pill.layer else { return }

        // ── Bar container ─────────────────────────────────────────────────────
        let totalBarW = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let barStartX = (overlayWidth - totalBarW) / 2
        let barContY  = (barsSectionH - maxBarHeight) / 2

        let container = CALayer()
        container.frame         = CGRect(x: barStartX, y: barContY, width: totalBarW, height: maxBarHeight)
        container.masksToBounds = false
        pillLayer.addSublayer(container)
        self.barContainerLayer = container

        barLayers = []
        for i in 0..<barCount {
            let barX = CGFloat(i) * (barWidth + barGap)
            let bar  = CAGradientLayer()
            bar.startPoint   = CGPoint(x: 0.5, y: 0.0)
            bar.endPoint     = CGPoint(x: 0.5, y: 1.0)
            bar.colors       = recordingColors
            bar.cornerRadius = barWidth / 2
            bar.bounds       = CGRect(x: 0, y: 0, width: barWidth, height: maxBarHeight)
            bar.anchorPoint  = CGPoint(x: 0.5, y: 0.0)
            bar.position     = CGPoint(x: barX + barWidth / 2, y: 0)
            bar.transform    = CATransform3DMakeScale(1.0, 0.08, 1.0)
            bar.shadowOpacity = 0.0
            bar.shadowRadius  = 5
            bar.shadowOffset  = .zero
            bar.shadowColor   = recordingShadow
            container.addSublayer(bar)
            barLayers.append(bar)
        }

        // ── Text label ────────────────────────────────────────────────────────
        let label = NSTextField(labelWithString: "")
        label.font            = .systemFont(ofSize: 13, weight: .regular)
        label.textColor       = NSColor(white: 0.12, alpha: 0.92)
        label.backgroundColor = .clear
        label.isBezeled       = false
        label.isEditable      = false
        label.alignment       = .center
        label.lineBreakMode   = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.frame           = CGRect(x: 22, y: 10, width: overlayWidth - 44, height: textSectionH - 18)
        label.alphaValue      = 0
        pill.addSubview(label)
        self.textLabel = label

        w.contentView = pill

        // ── Position: bottom-centre ───────────────────────────────────────────
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: sf.midX - overlayWidth / 2,
                                     y: sf.minY + 80))
        }

        self.window = w
        logInfo("RecordingOverlay", "Overlay ready (\(barCount) bars, 95% white)")
    }
}
