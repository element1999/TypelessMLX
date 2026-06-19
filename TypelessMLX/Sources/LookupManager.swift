import AppKit
import Carbon
import CoreServices

class LookupManager {
    static let shared = LookupManager()
    private var overlay: LookupOverlay?
    private weak var appState: AppState?

    private init() {}

    func setup(appState: AppState) {
        self.appState = appState
    }

    func lookup() {
        logInfo("LookupManager", "lookup() called, axPerm=\(appState?.hasAccessibilityPermission ?? false)")
        guard appState?.hasAccessibilityPermission == true else {
            logWarn("LookupManager", "Accessibility permission not granted")
            return
        }
        if let text = selectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logInfo("LookupManager", "selectedText=\(text.prefix(40))")
            lookupText(text)
        } else {
            logInfo("LookupManager", "AX failed, trying clipboard fallback")
            clipboardFallbackLookup()
        }
    }

    // Simulate Cmd+C to the frontmost app and read whatever lands on the clipboard.
    // Used when AX text selection is unavailable (e.g. Chrome).
    private func clipboardFallbackLookup() {
        let pb = NSPasteboard.general
        let prevCount = pb.changeCount
        postCopyEvent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard pb.changeCount != prevCount,
                  let text = pb.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logInfo("LookupManager", "Clipboard fallback: clipboard unchanged, no text")
                return
            }
            logInfo("LookupManager", "Clipboard fallback: \(text.prefix(40))")
            self?.lookupText(text)
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

    func lookupText(_ text: String) {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        logInfo("LookupManager", "lookupText: \(word.prefix(40))")
        let pt = NSEvent.mouseLocation

        DispatchQueue.main.async {
            logInfo("LookupManager", "showing overlay near (\(Int(pt.x)),\(Int(pt.y)))")
            self.overlay?.dismiss()
            let ov = LookupOverlay()
            self.overlay = ov
            ov.show(word: word, near: pt)
        }

        guard appState?.hasPythonBackend == true else {
            logInfo("LookupManager", "Python backend not ready, overlay shows 查询中… only")
            return
        }
        WhisperBridge.shared.lookup(text: word,
                                    textModel: AppState.shared.resolvedTextModelPath) { [weak self] result in
            let entry = (try? result.get()) ?? ""
            logInfo("LookupManager", "lookup result: \(entry.prefix(60))")
            DispatchQueue.main.async { self?.overlay?.setContent(entry) }
        }
    }

    private func selectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusErr == .success, let focused = focusedRef else {
            logInfo("LookupManager", "AX focus failed: \(focusErr.rawValue)")
            return nil
        }
        let axFocused = focused as! AXUIElement
        var selectedRef: CFTypeRef?
        let selErr = AXUIElementCopyAttributeValue(axFocused, kAXSelectedTextAttribute as CFString, &selectedRef)
        guard selErr == .success, let text = selectedRef as? String else {
            logInfo("LookupManager", "AX selectedText failed: \(selErr.rawValue)")
            return nil
        }
        return text
    }
}
