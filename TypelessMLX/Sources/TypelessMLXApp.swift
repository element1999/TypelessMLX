import SwiftUI
import AVFoundation

@main
struct TypelessMLXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    let appState = AppState.shared
    private var permissionCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCrashHandler()
        logInfo("App", "TypelessMLX launching...")

        // Menu bar only app — no Dock icon
        NSApp.setActivationPolicy(.accessory)

        // Setup status bar
        statusBarController = StatusBarController(appState: appState)

        // Check permissions
        checkPermissions()

        // Request speech recognition authorization (for live preview + macOS built-in model)
        SpeechStreamer.requestAuthorization { granted in
            logInfo("App", "Speech recognition authorization: \(granted)")
        }

        // Check if Python venv is ready; if not, show setup
        checkBackendAndSetup()

        // Pre-warm Apple Foundation Models session if enabled
        warmUpTextRefinerIfNeeded()

        // Setup hotkey (works even before permissions are fully granted)
        HotkeyManager.shared.setup(appState: appState)

        // Setup meeting subtitle engine
        MeetingCaptureEngine.shared.setup(appState: appState)

        // Setup dictionary lookup
        LookupManager.shared.setup(appState: appState)
        TranslateManager.shared.setup(appState: appState)

        // Register as macOS Services provider
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Periodically re-check permissions
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.recheckPermissions()
        }

        logInfo("App", "TypelessMLX launch complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionCheckTimer?.invalidate()
        logInfo("App", "TypelessMLX shutting down")
        AudioRecorder.shared.forceReset()
        WhisperBridge.shared.stopProcess()
        MeetingCaptureEngine.shared.stop()
    }

    // MARK: - macOS Services

    @objc func lookupSelectedText(_ pboard: NSPasteboard, userData: String,
                                   error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else { return }
        LookupManager.shared.lookupText(text)
    }

    private func installCrashHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let msg = "UNCAUGHT EXCEPTION: \(exception.name.rawValue) — \(exception.reason ?? "unknown")"
            logError("CRASH", msg)
            Thread.sleep(forTimeInterval: 0.5)
        }
        logInfo("App", "Crash handler installed")
    }

    private func checkPermissions() {
        logInfo("App", "Checking permissions...")

        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.appState.hasMicPermission = granted
                    self.appState.updatePermissionState()
                    if !granted {
                        self.appState.showError("麦克风访问被拒绝。请前往系统设置 → 隐私与安全性 → 麦克风 启用。")
                    }
                }
            }
        case .denied, .restricted:
            appState.hasMicPermission = false
            appState.showError("麦克风访问被拒绝。请前往系统设置 → 隐私与安全性 → 麦克风 启用。")
        case .authorized:
            appState.hasMicPermission = true
        @unknown default:
            break
        }

        // Accessibility
        let axTrusted = AXIsProcessTrusted()
        appState.hasAccessibilityPermission = axTrusted
        if !axTrusted {
            showAccessibilityAlert()
        }

        appState.updatePermissionState()
    }

    private func recheckPermissions() {
        let ax = AXIsProcessTrusted()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        DispatchQueue.main.async {
            let changed = (self.appState.hasAccessibilityPermission != ax) ||
                          (self.appState.hasMicPermission != mic)
            self.appState.hasAccessibilityPermission = ax
            self.appState.hasMicPermission = mic
            if changed { self.appState.updatePermissionState() }

            // If subtitle is enabled but stream not active, retry (e.g. after granting screen capture)
            if self.appState.meetingSubtitleEnabled && !self.appState.isTeamsMeetingActive {
                MeetingCaptureEngine.shared.setEnabled(true)
            }
        }
    }

    private func warmUpTextRefinerIfNeeded() {
        if #available(macOS 26, *) {
            if appState.enableTextRefinement {
                Task { await TextRefiner.shared.warmUp() }
            }
        }
    }

    private func checkBackendAndSetup() {
        if WhisperBridge.isVenvReady() {
            logInfo("App", "Python venv ready — starting WhisperBridge")
            WhisperBridge.shared.start { [weak self] success in
                self?.appState.hasPythonBackend = success
                self?.appState.updatePermissionState()
                logInfo("App", "WhisperBridge started: \(success)")
            }
        } else {
            logInfo("App", "Python venv not ready — showing setup")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SetupWindowController.shared.show {
                    logInfo("App", "Setup complete")
                }
            }
        }
    }

    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = """
            TypelessMLX 需要辅助功能权限，才能将识别文字粘贴到其他应用程序。

            请点击「打开设置」：
            1. 点击 + 按钮
            2. 选择 TypelessMLX.app 并添加
            3. 开启开关

            授权后可能需要重新启动 TypelessMLX。
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "稍后再说")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                TextPaster.openAccessibilitySettings()
            }
        }
    }
}
