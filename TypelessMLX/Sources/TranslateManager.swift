import AppKit
import Carbon

class TranslateManager {
    static let shared = TranslateManager()
    private var overlay: TranslateOverlay?
    private weak var appState: AppState?

    private init() {}

    func setup(appState: AppState) {
        self.appState = appState
    }

    func translate() {
        guard appState?.hasAccessibilityPermission == true else { return }
        if let text = selectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translateText(text)
        } else {
            clipboardFallbackTranslate()
        }
    }

    func translateText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logInfo("TranslateManager", "translateText: \(trimmed.prefix(60))")

        let cjkCount = trimmed.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let isChinese = cjkCount * 3 > trimmed.count
        let direction = isChinese ? "中 → EN" : "EN → 中"
        let pt = NSEvent.mouseLocation

        DispatchQueue.main.async {
            self.overlay?.dismiss()
            let ov = TranslateOverlay()
            self.overlay = ov
            ov.show(direction: direction, near: pt)
        }

        guard appState?.hasPythonBackend == true else { return }
        WhisperBridge.shared.translate(text: trimmed) { [weak self] result in
            let translation = (try? result.get()) ?? ""
            logInfo("TranslateManager", "translation: \(translation.prefix(60))")
            DispatchQueue.main.async { self?.overlay?.setContent(translation) }
        }
    }

    private func clipboardFallbackTranslate() {
        let pb = NSPasteboard.general
        let prevCount = pb.changeCount
        postCopyEvent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard pb.changeCount != prevCount,
                  let text = pb.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self?.translateText(text)
        }
    }

    private func postCopyEvent() {
        let src = CGEventSource(stateID: .hidSystemState)
        let dn = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        dn?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        up?.flags = .maskCommand
        dn?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func selectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let axFocused = focused as! AXUIElement
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axFocused, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let text = selectedRef as? String else { return nil }
        return text
    }
}
