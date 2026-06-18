import AppKit
import SwiftUI

// Carbon modifier bit values
private let kControlKey = 4096
private let kOptionKey  = 2048
private let kShiftKey   = 512
private let kCmdKey     = 256

struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let v = HotkeyRecorderNSView()
        v.keyCode = keyCode
        v.modifiers = modifiers
        v.onChange = { kc, mods in
            keyCode = kc
            modifiers = mods
        }
        return v
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        if !nsView.isRecording {
            nsView.keyCode = keyCode
            nsView.modifiers = modifiers
            nsView.refreshLabel()
        }
    }
}

class HotkeyRecorderNSView: NSView {
    var keyCode: Int = 0
    var modifiers: Int = 0
    var isRecording = false
    var onChange: ((Int, Int) -> Void)?

    private let label = NSTextField(labelWithString: "")

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1

        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        addSubview(label)

        refreshLabel()
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    func refreshLabel() {
        if isRecording {
            label.stringValue = "请按快捷键…"
            label.textColor = .controlAccentColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        } else {
            label.stringValue = HotkeyRecorderNSView.format(keyCode: keyCode, modifiers: modifiers)
            label.textColor = .labelColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isRecording = true
        refreshLabel()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        isRecording = false
        refreshLabel()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        let kc = Int(event.keyCode)

        if kc == 53 { // Esc = cancel
            window?.makeFirstResponder(nil)
            return
        }

        if Self.isModifierKey(kc) { return }

        let mods = Self.carbonModifiers(from: event.modifierFlags)
        guard mods != 0 else { return }

        keyCode = kc
        modifiers = mods
        onChange?(kc, mods)
        window?.makeFirstResponder(nil)
    }

    // MARK: - Static helpers

    static func format(keyCode: Int, modifiers: Int) -> String {
        var s = ""
        if modifiers & kControlKey != 0 { s += "⌃" }
        if modifiers & kOptionKey  != 0 { s += "⌥" }
        if modifiers & kShiftKey   != 0 { s += "⇧" }
        if modifiers & kCmdKey     != 0 { s += "⌘" }
        s += keyChar[keyCode] ?? "?"
        return s
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var c = 0
        if flags.contains(.control) { c |= kControlKey }
        if flags.contains(.option)  { c |= kOptionKey }
        if flags.contains(.shift)   { c |= kShiftKey }
        if flags.contains(.command) { c |= kCmdKey }
        return c
    }

    static func isModifierKey(_ kc: Int) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(kc)
    }

    static let keyChar: [Int: String] = [
         0: "A",  1: "S",  2: "D",  3: "F",  4: "H",  5: "G",  6: "Z",  7: "X",
         8: "C",  9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
