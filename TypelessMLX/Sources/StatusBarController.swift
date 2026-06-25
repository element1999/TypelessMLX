import AppKit
import SwiftUI
import Combine
import UserNotifications

class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var appState: AppState
    private var cancellables = Set<AnyCancellable>()
    private var pendingSelectedText: String?

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupButton()
        setupMenu()
        observeState()
    }

    private func setupButton() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "TypelessMLX")
            button.image?.isTemplate = true
        }
    }

    private func setupMenu() {
        updateMenu()
    }

    private func observeState() {
        appState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateIcon(for: status)
                self?.updateMenu()
            }
            .store(in: &cancellables)

        appState.$permissionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenu() }
            .store(in: &cancellables)

        appState.$isTeamsMeetingActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenu() }
            .store(in: &cancellables)

        appState.$errorMessage
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.showNotification(title: "TypelessMLX", body: message)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(for status: AppStatus) {
        guard let button = statusItem.button else { return }
        switch status {
        case .idle:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "TypelessMLX - 待机")
            button.image?.isTemplate = true
            button.contentTintColor = nil
        case .recording:
            button.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "TypelessMLX - 录音中")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
        case .transcribing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: "TypelessMLX - 识别中")
            button.image?.isTemplate = false
            button.contentTintColor = .systemOrange
        }
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Permission/status indicator
        let permItem = NSMenuItem(title: appState.permissionState.rawValue, action: nil, keyEquivalent: "")
        permItem.isEnabled = false
        menu.addItem(permItem)

        if appState.permissionState != .ready {
            if !appState.hasMicPermission {
                let item = NSMenuItem(title: "  ⚠️ 麦克风：未授权", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            if !appState.hasAccessibilityPermission {
                let item = NSMenuItem(title: "  ⚠️ 辅助功能：未授权", action: #selector(openAccessibilitySettings), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Current model
        let modelItem = NSMenuItem(title: "模型：\(appState.selectedModel.id)", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        // Status
        let statusItem = NSMenuItem(title: appState.status.rawValue, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        // Hotkey hint
        let modeText = appState.hotkeyMode == "hold" ? "按住录音" : "点击切换录音"
        let hintItem = NSMenuItem(title: "Right ⌥ Option → \(modeText)", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        let lookupLabel = HotkeyRecorderNSView.format(keyCode: appState.lookupHotkeyKeyCode,
                                                       modifiers: appState.lookupHotkeyModifiers)
        let translateLabel = HotkeyRecorderNSView.format(keyCode: appState.translateHotkeyKeyCode,
                                                          modifiers: appState.translateHotkeyModifiers)
        let translateItem = NSMenuItem(title: "翻译选中文字  (\(lookupLabel))", action: #selector(translateSelectedText), keyEquivalent: "")
        translateItem.target = self
        menu.addItem(translateItem)

        let translateSentenceItem = NSMenuItem(title: "翻译整句  (\(translateLabel))", action: #selector(translateSentence), keyEquivalent: "")
        translateSentenceItem.target = self
        menu.addItem(translateSentenceItem)

        let ocrLabel = HotkeyRecorderNSView.format(keyCode: appState.ocrHotkeyKeyCode,
                                                    modifiers: appState.ocrHotkeyModifiers)
        let ocrItem = NSMenuItem(title: "OCR 截图识别  (\(ocrLabel))", action: #selector(triggerOCR), keyEquivalent: "")
        ocrItem.target = self
        menu.addItem(ocrItem)

        // Last transcription
        if let lastEntry = appState.history.first {
            menu.addItem(NSMenuItem.separator())
            let preview = String(lastEntry.text.prefix(50)) + (lastEntry.text.count > 50 ? "…" : "")
            let lastItem = NSMenuItem(title: "最近：\(preview)", action: #selector(copyLastTranscription), keyEquivalent: "")
            lastItem.target = self
            lastItem.toolTip = lastEntry.text
            menu.addItem(lastItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Meeting subtitle section
        let subtitleHeader = NSMenuItem(title: "会议字幕", action: nil, keyEquivalent: "")
        subtitleHeader.isEnabled = false
        menu.addItem(subtitleHeader)

        let subtitleToggleTitle = appState.meetingSubtitleEnabled ? "  停止会议字幕" : "  开始会议字幕"
        let subtitleToggleItem = NSMenuItem(title: subtitleToggleTitle, action: #selector(toggleMeetingSubtitle), keyEquivalent: "")
        subtitleToggleItem.target = self
        menu.addItem(subtitleToggleItem)

        if appState.meetingSubtitleEnabled {
            if !appState.hasScreenCapturePermission {
                let permItem = NSMenuItem(title: "  ⚠️ 需要屏幕录制权限", action: #selector(openScreenCaptureSettings), keyEquivalent: "")
                permItem.target = self
                menu.addItem(permItem)
            } else {
                let captureState = appState.isTeamsMeetingActive ? "  ● 正在捕获系统音频" : "  ○ 正在启动..."
                let captureItem = NSMenuItem(title: captureState, action: nil, keyEquivalent: "")
                captureItem.isEnabled = false
                menu.addItem(captureItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Setup / Settings
        let setupItem = NSMenuItem(title: "设置与安装...", action: #selector(showSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        let settingsItem = NSMenuItem(title: "偏好设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let refreshItem = NSMenuItem(title: "刷新权限", action: #selector(refreshPermissions), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 TypelessMLX", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
        menu.delegate = self
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        pendingSelectedText = captureSelectedText()
        logInfo("StatusBar", "menuWillOpen, capturedText=\(pendingSelectedText?.prefix(30) ?? "nil")")
    }

    private func captureSelectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let axFocused = focused as! AXUIElement
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axFocused, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let text = selectedRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    @objc private func translateSelectedText() {
        if let text = pendingSelectedText {
            pendingSelectedText = nil
            LookupManager.shared.lookupText(text)
        } else {
            LookupManager.shared.lookup()
        }
    }

    @objc private func translateSentence() {
        if let text = pendingSelectedText {
            pendingSelectedText = nil
            TranslateManager.shared.translateText(text)
        } else {
            TranslateManager.shared.translate()
        }
    }

    @objc private func triggerOCR() {
        OCRManager.shared.startCapture()
    }

    @objc private func toggleMeetingSubtitle() {
        appState.meetingSubtitleEnabled.toggle()
        MeetingCaptureEngine.shared.setEnabled(appState.meetingSubtitleEnabled)
        updateMenu()
    }

    @objc private func openScreenCaptureSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openAccessibilitySettings() {
        TextPaster.openAccessibilitySettings()
    }

    @objc private func showSetup() {
        SetupWindowController.shared.show()
    }

    @objc private func copyLastTranscription() {
        guard let last = appState.history.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.text, forType: .string)
        showNotification(title: "已复制", body: String(last.text.prefix(50)))
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(appState: appState)
    }

    @objc private func refreshPermissions() {
        appState.refreshPermissions()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Settings Window Controller

class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(appState: AppState) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 380)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TypelessMLX 偏好设置"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
