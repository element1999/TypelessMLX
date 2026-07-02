import SwiftUI
import Combine
import AVFoundation
import AppKit

enum AppStatus: String {
    case idle = "待机中"
    case recording = "录音中..."
    case transcribing = "识别中..."
}

enum PermissionState: String {
    case ready = "🟢 就绪"
    case missingPermissions = "🟡 缺少权限"
    case error = "🔴 错误"
}

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    let duration: TimeInterval
    let model: String

    init(text: String, duration: TimeInterval, model: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.duration = duration
        self.model = model
    }
}

// MLX model definitions
struct MLXModel: Identifiable {
    let id: String          // display name / storage key
    let repoOrPath: String  // HuggingFace repo or local path (resolved at runtime)
    let description: String
    var isLocal: Bool       // true = local converted model, false = HF repo
    var modelType: String   // "whisper" | "qwen3"
}

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var status: AppStatus = .idle {
        didSet { logInfo("AppState", "Status: \(oldValue.rawValue) → \(status.rawValue)") }
    }
    @Published var errorMessage: String?
    @Published var history: [TranscriptionEntry] = []
    @Published var permissionState: PermissionState = .missingPermissions
    @Published var hasMicPermission: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    @Published var hasScreenCapturePermission: Bool = false
    @Published var isTeamsMeetingActive: Bool = false

    // Settings (persisted via AppStorage)
    @AppStorage("selectedModelID") var selectedModelID: String = "qwen3-asr-1.7b"
    @AppStorage("showFloatingOverlay") var showFloatingOverlay: Bool = true
    @AppStorage("playSounds") var playSounds: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("hotkeyKeyCode") var hotkeyKeyCode: Int = 61  // Right Option
    @AppStorage("language") var language: String = "auto"
    @AppStorage("hotkeyMode") var hotkeyMode: String = "hold"  // "toggle" or "hold"
    @AppStorage("maxHistoryCount") var maxHistoryCount: Int = 50
    @AppStorage("initialPrompt") var initialPrompt: String = ""
    @AppStorage("inputDeviceUID") var inputDeviceUID: String = ""  // empty = system default
    @AppStorage("enableTextRefinement") var enableTextRefinement: Bool = false
    @AppStorage("removeFillers") var removeFillers: Bool = false
    @AppStorage("meetingSubtitleEnabled") var meetingSubtitleEnabled: Bool = false
    @AppStorage("subtitleRefreshIntervalSeconds") var subtitleRefreshIntervalSeconds: Double = 0.5
    @AppStorage("customCACertPath") var customCACertPath: String = ""
    @AppStorage("lookupHotkeyKeyCode") var lookupHotkeyKeyCode: Int = 2        // kVK_ANSI_D
    @AppStorage("lookupHotkeyModifiers") var lookupHotkeyModifiers: Int = 6144  // controlKey | optionKey
    @AppStorage("translateHotkeyKeyCode") var translateHotkeyKeyCode: Int = 17  // kVK_ANSI_T
    @AppStorage("translateHotkeyModifiers") var translateHotkeyModifiers: Int = 6144
    @AppStorage("ocrHotkeyKeyCode")        var ocrHotkeyKeyCode: Int        = 31    // kVK_ANSI_O
    @AppStorage("ocrHotkeyModifiers")      var ocrHotkeyModifiers: Int      = 6144  // controlKey | optionKey
    @AppStorage("snipPinHotkeyKeyCode")    var snipPinHotkeyKeyCode: Int    = 38    // kVK_ANSI_J
    @AppStorage("snipPinHotkeyModifiers")  var snipPinHotkeyModifiers: Int  = 6144  // controlKey | optionKey
    // Live transcription text (set by ASR progress callbacks)
    @Published var liveTranscriptionConfirmedText: String = ""
    @Published var liveTranscriptionUnconfirmedText: String = ""
    private var lastModelCacheAlertAt: Date = .distantPast
    private let modelCacheAlertCooldown: TimeInterval = 8

    // Available MLX models
    static let availableModels: [MLXModel] = [
        MLXModel(
            id: "macos-speech",
            repoOrPath: "",
            description: "macOS 内置语音识别（快速、无需下载）",
            isLocal: true, modelType: "macos"
        ),
        MLXModel(
            id: "qwen3-asr-0.6b",
            repoOrPath: "mlx-community/Qwen3-ASR-0.6B-8bit",
            description: "Qwen3-ASR 0.6B（中文精度最佳，~1GB，推荐）",
            isLocal: false, modelType: "qwen3"
        ),
        MLXModel(
            id: "qwen3-asr-1.7b",
            repoOrPath: "mlx-community/Qwen3-ASR-1.7B-8bit",
            description: "Qwen3-ASR 1.7B（更高精度，~2GB）",
            isLocal: false, modelType: "qwen3"
        ),
        MLXModel(
            id: "whisper-large-v3-947m",
            repoOrPath: "argmaxinc/whisperkit-coreml",
            description: "WhisperKit Large v3 947M（多语言，最高精度）",
            isLocal: false, modelType: "whisper"
        ),
        MLXModel(
            id: "whisper-large-v3-turbo-632m",
            repoOrPath: "argmaxinc/whisperkit-coreml",
            description: "WhisperKit Large v3 Turbo 632M（多语言，速度/体积平衡）",
            isLocal: false, modelType: "whisper"
        ),
        MLXModel(
            id: "whisper-small-216m",
            repoOrPath: "argmaxinc/whisperkit-coreml",
            description: "WhisperKit Small 216M（多语言，最快）",
            isLocal: false, modelType: "whisper"
        ),
    ]

    var selectedModel: MLXModel {
        Self.availableModels.first { $0.id == selectedModelID } ?? Self.availableModels[0]
    }

    /// Resolved model path or HF repo for native ASR backends.
    var resolvedModelPath: String {
        let model = selectedModel
        if model.isLocal { return model.repoOrPath }
        // Check app bundle Resources/models/<id>/ first (for offline distribution)
        if let bundled = Self.bundledModelPath(for: model) { return bundled }
        return model.repoOrPath
    }

    static func bundledModelPath(for model: MLXModel) -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = resourcePath + "/models/" + model.id
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func whisperKitVariant(for modelID: String) -> String? {
        switch modelID {
        case "whisper-large-v3-947m": return "openai_whisper-large-v3_947MB"
        case "whisper-large-v3-turbo-632m": return "openai_whisper-large-v3-v20240930_turbo_632MB"
        case "whisper-small-216m": return "openai_whisper-small_216MB"
        default: return nil
        }
    }

    static func whisperKitTokenizerResourceSubpath(for modelID: String) -> String? {
        switch modelID {
        case "whisper-large-v3-947m", "whisper-large-v3-turbo-632m": return "models/openai/whisper-large-v3"
        case "whisper-small-216m": return "models/openai/whisper-small"
        default: return nil
        }
    }

    /// Resolved model path for meeting subtitle — always a Whisper model
    var resolvedSubtitleModelPath: String {
        if selectedModel.modelType == "whisper" { return resolvedModelPath }
        let whisperModels = Self.availableModels.filter { $0.modelType == "whisper" }
        for m in whisperModels {
            if let bundled = Self.bundledModelPath(for: m) { return bundled }
        }
        return "argmaxinc/whisperkit-coreml"
    }
    /// Text model for lookup / translation.
    var resolvedTextModelPath: String {
        return "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    }

    private func normalizeHotkeyDefaults() {
        switch selectedModelID {
        case "whisper-large-v3": selectedModelID = "whisper-large-v3-947m"
        case "whisper-medium": selectedModelID = "whisper-large-v3-turbo-632m"
        case "whisper-small": selectedModelID = "whisper-small-216m"
        default: break
        }
        if !Self.availableModels.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = "qwen3-asr-1.7b"
        }

        let defaultModifiers = 6144  // controlKey | optionKey

        func isInvalidHotkey(_ keyCode: Int, _ modifiers: Int) -> Bool {
            if modifiers == 0 { return true }
            if keyCode <= 0 { return true }
            if HotkeyRecorderNSView.isModifierKey(keyCode) { return true }
            return HotkeyRecorderNSView.keyChar[keyCode] == nil
        }

        if isInvalidHotkey(lookupHotkeyKeyCode, lookupHotkeyModifiers) {
            lookupHotkeyKeyCode = 2    // D
            lookupHotkeyModifiers = defaultModifiers
        }
        if isInvalidHotkey(translateHotkeyKeyCode, translateHotkeyModifiers) {
            translateHotkeyKeyCode = 17  // T
            translateHotkeyModifiers = defaultModifiers
        }
        if isInvalidHotkey(ocrHotkeyKeyCode, ocrHotkeyModifiers) {
            ocrHotkeyKeyCode = 31  // O
            ocrHotkeyModifiers = defaultModifiers
        }
        if isInvalidHotkey(snipPinHotkeyKeyCode, snipPinHotkeyModifiers) {
            snipPinHotkeyKeyCode = 38  // J
            snipPinHotkeyModifiers = defaultModifiers
        }
    }

    private init() {
        normalizeHotkeyDefaults()
        loadHistory()
        logInfo("AppState", "Initialized. Model=\(selectedModelID), Language=\(language), Mode=\(hotkeyMode)")
    }

    func setStatus(_ newStatus: AppStatus) {
        if Thread.isMainThread {
            self.status = newStatus
        } else {
            DispatchQueue.main.async { self.status = newStatus }
        }
    }

    func showError(_ message: String) {
        logError("AppState", "Error: \(message)")
        if Thread.isMainThread {
            self.errorMessage = message
        } else {
            DispatchQueue.main.async { self.errorMessage = message }
        }
    }

    func showModelCacheAlert(feature: String, modelId: String) {
        let message = "\(feature)所需模型本地缓存不可用：\(modelId)。请在“偏好设置 → 模型”手动下载；若已下载，请删除后重新下载。"
        logError("AppState", "Model cache issue: \(message)")

        let present = {
            let now = Date()
            if now.timeIntervalSince(self.lastModelCacheAlertAt) < self.modelCacheAlertCooldown {
                self.errorMessage = message
                return
            }
            self.lastModelCacheAlertAt = now
            self.errorMessage = message

            let alert = NSAlert()
            alert.messageText = "模型缓存异常"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开偏好设置")
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }

        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async { present() }
        }
    }

    func updatePermissionState() {
        if hasMicPermission && hasAccessibilityPermission {
            permissionState = .ready
        } else {
            permissionState = .missingPermissions
        }
        logInfo("AppState", "Permission state: \(permissionState.rawValue) [mic=\(hasMicPermission) ax=\(hasAccessibilityPermission)]")
    }

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        DispatchQueue.main.async {
            self.hasMicPermission = mic
            self.hasAccessibilityPermission = ax
            self.updatePermissionState()
        }
    }

    func addToHistory(_ entry: TranscriptionEntry) {
        let work = {
            self.history.insert(entry, at: 0)
            if self.history.count > self.maxHistoryCount {
                self.history = Array(self.history.prefix(self.maxHistoryCount))
            }
            self.saveHistory()
        }
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async { work() } }
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private var historyURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/typelessmlx")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(history)
            try data.write(to: historyURL)
        } catch {
            logError("AppState", "Failed to save history: \(error)")
        }
    }

    private func loadHistory() {
        do {
            let data = try Data(contentsOf: historyURL)
            history = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
            logInfo("AppState", "Loaded \(history.count) history entries")
        } catch {
            logDebug("AppState", "No history: \(error.localizedDescription)")
        }
    }
}
