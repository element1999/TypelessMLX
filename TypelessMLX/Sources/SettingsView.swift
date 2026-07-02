import SwiftUI
import AVFoundation
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .environmentObject(appState)
                .tabItem { Label("一般", systemImage: "gear") }
                .tag(0)

            ModelSettingsTab()
                .environmentObject(appState)
                .tabItem { Label("模型", systemImage: "waveform") }
                .tag(1)

            HistorySettingsTab()
                .environmentObject(appState)
                .tabItem { Label("历史", systemImage: "clock") }
                .tag(2)
        }
        .frame(width: 480, height: 420)
        .padding()
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var inputDevices: [(name: String, uid: String)] = []

    var body: some View {
        Form {
            Section("快捷键") {
                HStack {
                    Text("识别快捷键")
                    Spacer()
                    Text(hotkeyDisplayName).foregroundColor(.secondary)
                }

                Picker("模式", selection: $appState.hotkeyMode) {
                    Text("切换模式（点击开始，再按停止）").tag("toggle")
                    Text("按住模式（按住录音，松开停止）").tag("hold")
                }

                HStack {
                    Text("查词快捷键")
                    Spacer()
                    HotkeyRecorderField(keyCode: $appState.lookupHotkeyKeyCode,
                                        modifiers: $appState.lookupHotkeyModifiers)
                        .frame(width: 110, height: 28)
                }

                HStack {
                    Text("翻译快捷键")
                    Spacer()
                    HotkeyRecorderField(keyCode: $appState.translateHotkeyKeyCode,
                                        modifiers: $appState.translateHotkeyModifiers)
                        .frame(width: 110, height: 28)
                }

                HStack {
                    Text("OCR 快捷键")
                    Spacer()
                    HotkeyRecorderField(keyCode: $appState.ocrHotkeyKeyCode,
                                        modifiers: $appState.ocrHotkeyModifiers)
                        .frame(width: 110, height: 28)
                }

                HStack {
                    Text("截图并贴图快捷键")
                    Spacer()
                    HotkeyRecorderField(keyCode: $appState.snipPinHotkeyKeyCode,
                                        modifiers: $appState.snipPinHotkeyModifiers)
                        .frame(width: 110, height: 28)
                }
            }

            Section("录音设备") {
                Picker("输入设备", selection: $appState.inputDeviceUID) {
                    Text("系统默认").tag("")
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }

            Section("显示") {
                Toggle("显示悬浮录音指示器", isOn: $appState.showFloatingOverlay)
                Toggle("开机自动启动", isOn: $appState.launchAtLogin)
                    .onChange(of: appState.launchAtLogin) { newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section("网络") {
                HStack(alignment: .firstTextBaseline) {
                    Text("CA 证书路径")
                    Spacer()
                    TextField("~/combined_cert.pem", text: $appState.customCACertPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                Text("企业内网证书路径（PEM 格式）。填写后需先将证书导入系统钥匙串：\nsudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <证书路径>")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("权限状态") {
                HStack {
                    Text("麦克风")
                    Spacer()
                    PermissionBadge(granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
                }
                HStack {
                    Text("辅助功能（Accessibility）")
                    Spacer()
                    PermissionBadge(granted: AXIsProcessTrusted())
                }
                Button("打开系统设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
                .buttonStyle(.link)
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(appVersion).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            inputDevices = AudioRecorder.availableInputDevices()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (build \(build))"
    }

    private var hotkeyDisplayName: String {
        switch appState.hotkeyKeyCode {
        case 61: return "Right ⌥ Option"
        case 58: return "Left ⌥ Option"
        default: return "Key \(appState.hotkeyKeyCode)"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                logWarn("Settings", "Failed to set launch at login: \(error)")
            }
        }
    }
}

struct PermissionBadge: View {
    let granted: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(granted ? .green : .red)
            Text(granted ? "已授权" : "未授权")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Model Row

struct ModelRow: View {
    let model: MLXModel
    let isSelected: Bool
    let isCached: Bool
    let sizeString: String
    let isDownloading: Bool
    let downloadStatusText: String
    let anyDownloading: Bool
    let isSelectable: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Left: name + status badge + description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.id).font(.body.bold())
                    cacheStatusBadge
                }
                Text(model.description).font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            // Right: action buttons + selected checkmark
            HStack(spacing: 6) {
                if !model.isLocal {
                    if isDownloading {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                            Text(downloadStatusText.isEmpty ? "下载中..." : downloadStatusText)
                                .font(.caption).foregroundColor(.orange)
                        }
                    } else if isCached {
                        Button(action: onDelete) {
                            Image(systemName: "trash").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help("删除本地缓存")
                    } else {
                        Button(action: onDownload) {
                            Label("下载", systemImage: "arrow.down.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(anyDownloading)
                    }
                }

                if isSelected {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelectable else { return }
            onSelect()
        }
    }

    @ViewBuilder
    private var cacheStatusBadge: some View {
        if model.isLocal {
            // macOS built-in — always ready, no badge needed
            EmptyView()
        } else if isDownloading {
            EmptyView()
        } else if isCached {
            badge(sizeString.isEmpty ? "已下载" : sizeString, color: .green)
        } else {
            badge("未下载", color: .secondary)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.1))
            .cornerRadius(4)
    }
}

// MARK: - Model Tab

struct ModelSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var modelManager = ModelManager.shared
    @State private var dictionaryTerms: String = DictionaryService.shared.rawTerms
    @State private var deleteConfirmModelID: String?

    var body: some View {
        Form {
            Section("ASR 模型") {
                ForEach(AppState.availableModels) { model in
                    ModelRow(
                        model: model,
                        isSelected: appState.selectedModelID == model.id,
                        isCached: modelManager.isCached(model),
                        sizeString: modelManager.sizeString(for: model),
                        isDownloading: modelManager.downloadingModelID == model.id,
                        downloadStatusText: modelManager.downloadStatusText,
                        anyDownloading: modelManager.downloadingModelID != nil,
                        isSelectable: modelManager.isSelectable(model),
                        onSelect: { appState.selectedModelID = model.id },
                        onDownload: { modelManager.download(model) },
                        onDelete: { deleteConfirmModelID = model.id }
                    )
                    .padding(.vertical, 2)
                }
            }
            .onAppear { modelManager.refreshAllStatuses() }
            .alert("删除模型缓存", isPresented: Binding(
                get: { deleteConfirmModelID != nil },
                set: { if !$0 { deleteConfirmModelID = nil } }
            )) {
                Button("取消", role: .cancel) { deleteConfirmModelID = nil }
                Button("删除", role: .destructive) {
                    if let id = deleteConfirmModelID,
                       let model = AppState.downloadableModels.first(where: { $0.id == id }) {
                        try? modelManager.delete(model)
                    }
                    deleteConfirmModelID = nil
                }
            } message: {
                if let id = deleteConfirmModelID,
                   let model = AppState.downloadableModels.first(where: { $0.id == id }) {
                    Text("确定要删除「\(model.id)」的本地缓存吗？下次使用时需要重新下载。")
                }
            }
            .alert("下载失败", isPresented: Binding(
                get: { modelManager.downloadError != nil },
                set: { if !$0 { modelManager.downloadError = nil } }
            )) {
                Button("重试") {
                    if let errMsg = modelManager.downloadError,
                       let id = errMsg.components(separatedBy: "：").last,
                       let model = AppState.downloadableModels.first(where: { $0.id == id }) {
                        modelManager.downloadError = nil
                        modelManager.download(model)
                    }
                }
                Button("取消", role: .cancel) { modelManager.downloadError = nil }
            } message: {
                Text(modelManager.downloadError ?? "")
            }

            Section("翻译/查词模型") {
                let textModel = AppState.textModel
                ModelRow(
                    model: textModel,
                    isSelected: false,
                    isCached: modelManager.isCached(textModel),
                    sizeString: modelManager.sizeString(for: textModel),
                    isDownloading: modelManager.downloadingModelID == textModel.id,
                    downloadStatusText: modelManager.downloadStatusText,
                    anyDownloading: modelManager.downloadingModelID != nil,
                    isSelectable: false,
                    onSelect: {},
                    onDownload: { modelManager.download(textModel) },
                    onDelete: { deleteConfirmModelID = textModel.id }
                )
                .padding(.vertical, 2)
            }

            Section("语言") {
                Picker("识别语言", selection: $appState.language) {
                    Text("自动检测").tag("auto")
                    Text("中文（简体）").tag("zh")
                    Text("英文").tag("en")
                    Text("日文").tag("ja")
                }
            }

            Section(header: Text("实时字幕"),
                    footer: Text("调大刷新间隔可减少快语速时的字幕闪烁；调小则预览更实时。")) {
                HStack {
                    Text("刷新间隔")
                    Spacer()
                    Text(String(format: "%.1f 秒", appState.subtitleRefreshIntervalSeconds))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $appState.subtitleRefreshIntervalSeconds, in: 0.5...2.0, step: 0.1)
            }

            Section("文字后处理") {
                Toggle("启用文字修正", isOn: $appState.enableTextRefinement)
                    .onChange(of: appState.enableTextRefinement) { newValue in
                        if newValue, #available(macOS 26, *) {
                            Task { await TextRefiner.shared.warmUp() }
                        }
                    }
                Text("使用 Apple Foundation Models 修正最终识别文本的标点与错字，需 macOS 26 + Apple Intelligence；默认关闭以减少延迟。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("移除语音犹豫词（呃、嗯、啊…）", isOn: $appState.removeFillers)
                Text("本地规则处理，无需 Apple Intelligence；作用于语音输入实时预览、会议字幕和最终文本，仅移除独立的无语义犹豫词，不影响「那个」「就是」等词汇。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section(header: Text("提示词（Initial Prompt）"),
                    footer: Text("引导识别结果的格式与语言风格，可留空")) {
                TextEditor(text: $appState.initialPrompt)
                    .font(.body)
                    .frame(height: 72)
                    .overlay(alignment: .topLeading) {
                        if appState.initialPrompt.isEmpty {
                            Text("例：以下是普通话语音识别结果。")
                                .foregroundColor(.secondary.opacity(0.6))
                                .font(.body)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                Text("提示词与自定义词典合计上限 600 字符，请只保留最关键的专名或语境。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section(header: Text("自定义词典"),
                    footer: Text("一行一个词，识别时自动注入提示词提升精度（例：专有名词、品牌名称、缩写）")) {
                TextEditor(text: $dictionaryTerms)
                    .font(.body.monospaced())
                    .frame(height: 80)
                    .overlay(alignment: .topLeading) {
                        if dictionaryTerms.isEmpty {
                            Text("例：TypelessMLX\nBreeze-ASR")
                                .foregroundColor(.secondary.opacity(0.6))
                                .font(.body.monospaced())
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: dictionaryTerms) { newValue in
                        DictionaryService.shared.rawTerms = newValue
                    }
            
                HStack {
                    Spacer()
                    Button("恢复默认词典") {
                        DictionaryService.shared.resetToDefaultTerms()
                        dictionaryTerms = DictionaryService.shared.rawTerms
                    }
                    .controlSize(.small)
                }
}

        }
        .formStyle(.grouped)
    }
}

// MARK: - History Tab

struct HistorySettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Stepper("保留 \(appState.maxHistoryCount) 条记录",
                        value: $appState.maxHistoryCount, in: 10...200, step: 10)
                Button("清除所有历史", role: .destructive) {
                    appState.clearHistory()
                }
            }

            Section("最近识别") {
                if appState.history.isEmpty {
                    Text("暂无识别记录").foregroundColor(.secondary)
                } else {
                    List(appState.history.prefix(20)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text).lineLimit(2).font(.body)
                            HStack {
                                Text(entry.timestamp, style: .relative)
                                Text("• \(String(format: "%.1fs", entry.duration))")
                                Text("• \(entry.model)")
                            }
                            .font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
