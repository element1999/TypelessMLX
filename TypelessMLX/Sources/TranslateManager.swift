import AppKit
import Carbon

class TranslateManager {
    static let shared = TranslateManager()
    private var overlay: TranslateOverlay?
    private weak var appState: AppState?
    private let autoRetryDelay: TimeInterval = 0.8

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

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let translation = try await LLMService.shared.translate(trimmed)
                await MainActor.run {
                    if translation.isEmpty {
                        self.overlay?.setContent("无结果")
                    } else {
                        self.overlay?.setContent(translation)
                    }
                }
            } catch {
                logError("TranslateManager", "translate failed: \(error)")
                await MainActor.run { self.overlay?.setContent("翻译失败") }
            }
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
