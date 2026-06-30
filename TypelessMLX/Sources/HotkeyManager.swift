import Cocoa
import Carbon
import AVFoundation

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var appState: AppState?
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var lookupHotKeyRef: EventHotKeyRef?
    private var translateHotKeyRef: EventHotKeyRef?
    private var ocrHotKeyRef: EventHotKeyRef?
    private var snipPinHotKeyRef: EventHotKeyRef?
    private var carbonHandlerInstalled = false
    private var lastLookupKeyCode = -1
    private var lastLookupModifiers = -1
    private var lastTranslateKeyCode = -1
    private var lastTranslateModifiers = -1
    private var lastOcrKeyCode = -1
    private var lastOcrModifiers = -1
    private var lastSnipPinKeyCode = -1
    private var lastSnipPinModifiers = -1
    private var isRecording = false
    private var recordingStartTime: Date?
    private var overlay: RecordingOverlay?
    private let lock = NSLock()
    private var isProcessing = false
    private var consecutiveFailures = 0
    private let liveDraftQueue = DispatchQueue(label: "com.typelessmlx.live-draft", qos: .userInitiated)
    private var liveDraftBuffer: [Float] = []
    private var liveDraftSampleRate: Int = 16000
    private var liveDraftTask: Task<Void, Never>?
    private var liveDraftGeneration: UInt64 = 0
    private var liveDraftLastSampleCount: Int = 0
    private var liveDraftInFlight = false
    private static let liveDraftMaxWindowSeconds: Double = 8
    private static let liveDraftMinIntervalSeconds: Double = 0.8
    private static let liveDraftMinDeltaSeconds: Double = 0.35
    private static let maxConsecutiveFailures = 3

    private init() {}

    func setup(appState: AppState) {
        self.appState = appState
        self.overlay = RecordingOverlay()
        setupMonitors()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioDeviceLost),
            name: .audioDeviceLost,
            object: nil
        )
        logInfo("HotkeyManager", "Setup. keyCode=\(appState.hotkeyKeyCode), mode=\(appState.hotkeyMode)")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func handleAudioDeviceLost() {
        logError("HotkeyManager", "Audio device lost during recording")
        guard let appState = appState else { return }
        handleFailure(appState: appState, message: "录音设备中断，请重新连接麦克风")
    }

    private func setupMonitors() {
        // Global monitor — fires when other apps are focused
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // Local monitor — fires when our app is focused
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        logInfo("HotkeyManager", "Flag monitors registered")
        registerCarbonHotKeys()
    }

    private func registerCarbonHotKeys() {
        if !carbonHandlerInstalled {
            var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event!, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                switch hkID.id {
                case 1: DispatchQueue.main.async { LookupManager.shared.lookup() }
                case 2: DispatchQueue.main.async { TranslateManager.shared.translate() }
                case 3: DispatchQueue.main.async { OCRManager.shared.startCapture() }
                case 4: DispatchQueue.main.async { SnipManager.shared.startPinCapture() }
                default: break
                }
                return noErr
            }, 1, &eventSpec, nil, nil)
            carbonHandlerInstalled = true
            logInfo("HotkeyManager", "Carbon event handler installed")
        }
        registerHotKeyBindings()
    }

    private func registerHotKeyBindings() {
        if let ref = lookupHotKeyRef    { UnregisterEventHotKey(ref); lookupHotKeyRef = nil }
        if let ref = translateHotKeyRef { UnregisterEventHotKey(ref); translateHotKeyRef = nil }
        if let ref = ocrHotKeyRef       { UnregisterEventHotKey(ref); ocrHotKeyRef = nil }
        if let ref = snipPinHotKeyRef   { UnregisterEventHotKey(ref); snipPinHotKeyRef = nil }

        guard let appState = appState else { return }

        let lkc = appState.lookupHotkeyKeyCode
        let lm  = appState.lookupHotkeyModifiers
        let tkc = appState.translateHotkeyKeyCode
        let tm  = appState.translateHotkeyModifiers
        let okc = appState.ocrHotkeyKeyCode
        let om  = appState.ocrHotkeyModifiers
        let spkc = appState.snipPinHotkeyKeyCode
        let spm  = appState.snipPinHotkeyModifiers

        lastLookupKeyCode    = lkc; lastLookupModifiers    = lm
        lastTranslateKeyCode = tkc; lastTranslateModifiers = tm
        lastOcrKeyCode       = okc; lastOcrModifiers       = om
        lastSnipPinKeyCode   = spkc; lastSnipPinModifiers   = spm

        var lookupID = EventHotKeyID()
        lookupID.signature = 0x544C4D58
        lookupID.id = 1
        let ls = RegisterEventHotKey(UInt32(lkc), UInt32(lm),
                                     lookupID, GetApplicationEventTarget(), 0, &lookupHotKeyRef)
        if ls == noErr {
            logInfo("HotkeyManager", "Lookup hotkey registered: kc=\(lkc) mods=\(lm)")
        } else {
            logError("HotkeyManager", "Lookup hotkey registration failed: \(ls)")
        }

        var translateID = EventHotKeyID()
        translateID.signature = 0x544C4D58
        translateID.id = 2
        let ts = RegisterEventHotKey(UInt32(tkc), UInt32(tm),
                                     translateID, GetApplicationEventTarget(), 0, &translateHotKeyRef)
        if ts == noErr {
            logInfo("HotkeyManager", "Translate hotkey registered: kc=\(tkc) mods=\(tm)")
        } else {
            logError("HotkeyManager", "Translate hotkey registration failed: \(ts)")
        }

        var ocrID = EventHotKeyID()
        ocrID.signature = 0x544C4D58
        ocrID.id = 3
        let os = RegisterEventHotKey(UInt32(okc), UInt32(om),
                                     ocrID, GetApplicationEventTarget(), 0, &ocrHotKeyRef)
        if os == noErr {
            logInfo("HotkeyManager", "OCR hotkey registered: kc=\(okc) mods=\(om)")
        } else {
            logError("HotkeyManager", "OCR hotkey registration failed: \(os)")
        }

        var snipPinID = EventHotKeyID()
        snipPinID.signature = 0x544C4D58
        snipPinID.id = 4
        let sps = RegisterEventHotKey(UInt32(spkc), UInt32(spm),
                                      snipPinID, GetApplicationEventTarget(), 0, &snipPinHotKeyRef)
        if sps == noErr {
            logInfo("HotkeyManager", "Snip hotkey registered: kc=\(spkc) mods=\(spm)")
        } else {
            logError("HotkeyManager", "Snip hotkey registration failed: \(sps)")
        }
    }

    @objc private func userDefaultsChanged() {
        guard let appState = appState else { return }
        let lkc = appState.lookupHotkeyKeyCode
        let lm  = appState.lookupHotkeyModifiers
        let tkc = appState.translateHotkeyKeyCode
        let tm  = appState.translateHotkeyModifiers
        let okc = appState.ocrHotkeyKeyCode
        let om  = appState.ocrHotkeyModifiers
        let spkc = appState.snipPinHotkeyKeyCode
        let spm  = appState.snipPinHotkeyModifiers
        guard lkc != lastLookupKeyCode || lm != lastLookupModifiers ||
              tkc != lastTranslateKeyCode || tm != lastTranslateModifiers ||
              okc != lastOcrKeyCode || om != lastOcrModifiers ||
              spkc != lastSnipPinKeyCode || spm != lastSnipPinModifiers else { return }
        registerHotKeyBindings()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let appState = appState else { return }

        let keyCode = Int(event.keyCode)
        guard keyCode == appState.hotkeyKeyCode else { return }

        let isKeyPressed = event.modifierFlags.contains(.option)
        let mode = appState.hotkeyMode

        lock.lock()
        let currentlyRecording = isRecording
        let processing = isProcessing
        lock.unlock()

        DispatchQueue.main.async {
            if mode == "hold" {
                // Hold-to-talk: press=start, release=stop
                if isKeyPressed && !currentlyRecording && !processing {
                    self.startRecording()
                } else if !isKeyPressed && currentlyRecording {
                    self.stopRecordingAndTranscribe()
                }
            } else {
                // Toggle mode: each key-down toggles
                if isKeyPressed {  // key-down event
                    if !currentlyRecording && !processing {
                        self.startRecording()
                    } else if currentlyRecording {
                        self.stopRecordingAndTranscribe()
                    }
                }
                // key-up (isKeyPressed=false) is ignored in toggle mode
            }
        }
    }

    private func startRecording() {
        guard let appState = appState else { return }

        lock.lock()
        guard !isRecording && !isProcessing else {
            lock.unlock()
            return
        }

        let currentStatus = appState.status
        guard currentStatus == .idle else {
            lock.unlock()
            return
        }

        isRecording = true
        isProcessing = true
        recordingStartTime = Date()
        lock.unlock()

        appState.setStatus(.recording)
        appState.liveTranscriptionConfirmedText = ""
        appState.liveTranscriptionUnconfirmedText = ""

        if appState.showFloatingOverlay {
            overlay?.show(text: "🎙 录音中...", isRecording: true)
        }

        // Wire audio level → overlay bars
        if appState.showFloatingOverlay, let ov = overlay {
            AudioRecorder.shared.audioLevelHandler = { level in
                ov.updateAudioLevel(level)
            }
        }

        // Start live draft preview using the selected ASR model.
        let liveLanguage = appState.language == "auto" ? nil : appState.language
        let ov = overlay
        if appState.selectedModel.modelType == "macos" {
            SpeechStreamer.shared.startStreaming(language: liveLanguage)
            SpeechStreamer.shared.liveTextHandler = { text in
                ov?.updateLiveText(text)
            }
            AudioRecorder.shared.audioBufferHandler = { buffer in
                SpeechStreamer.shared.appendBuffer(buffer)
            }
            stopModelLiveDraft()
        } else {
            SpeechStreamer.shared.cancelStreaming()
            SpeechStreamer.shared.liveTextHandler = nil
            AudioRecorder.shared.audioBufferHandler = { [weak self] buffer in
                self?.appendLiveDraftBuffer(buffer)
            }
            startModelLiveDraft(modelType: appState.selectedModel.modelType, language: liveLanguage)
        }

        guard AudioRecorder.shared.startRecording() else {
            AudioRecorder.shared.audioLevelHandler = nil
            AudioRecorder.shared.audioBufferHandler = nil
            SpeechStreamer.shared.cancelStreaming()
            handleFailure(appState: appState, message: "找不到可用的音频输入设备，请连接或选择麦克风")
            return
        }

        lock.lock()
        isProcessing = false
        lock.unlock()

        logInfo("HotkeyManager", "Recording started")
    }

    private func stopRecordingAndTranscribe() {
        guard let appState = appState else { return }

        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }
        isRecording = false
        isProcessing = true
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        lock.unlock()

        logInfo("HotkeyManager", "Recording duration: \(String(format: "%.1f", duration))s")

        AudioRecorder.shared.audioLevelHandler = nil
        AudioRecorder.shared.audioBufferHandler = nil
        if appState.selectedModel.modelType == "macos" {
            SpeechStreamer.shared.stopStreaming()
        } else {
            stopModelLiveDraft()
        }

        AudioRecorder.shared.stopRecording { [weak self] audioURL in
            guard let self = self else { return }

            guard let audioURL = audioURL else {
                logError("HotkeyManager", "stopRecording returned nil URL")
                SpeechStreamer.shared.cancelStreaming()
                self.handleFailure(appState: appState, message: "录音失败，未获取到音频文件")
                return
            }

            // Skip very short recordings (< 0.3s)
            if duration < 0.3 {
                logInfo("HotkeyManager", "Recording too short (\(String(format: "%.2f", duration))s), skipping")
                SpeechStreamer.shared.cancelStreaming()
                self.resetState()
                DispatchQueue.main.async {
                    appState.setStatus(.idle)
                    self.overlay?.hide()
                }
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            DispatchQueue.main.async {
                appState.setStatus(.transcribing)
                if appState.showFloatingOverlay {
                    self.overlay?.show(text: "⏳ 识别中...", isRecording: false)
                }
            }

            let language = appState.language == "auto" ? nil : appState.language

            let handleResult: (Result<String, Error>) -> Void = { [weak self] result in
                guard let self = self else { return }
                try? FileManager.default.removeItem(at: audioURL)

                DispatchQueue.main.async {
                    // Clear live text pill — final result replaces it
                    self.overlay?.updateLiveText("")
                    self.overlay?.hide()

                    switch result {
                    case .success(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else {
                            logWarn("HotkeyManager", "Transcription returned empty text")
                            self.resetState()
                            appState.setStatus(.idle)
                            return
                        }

                        logInfo("HotkeyManager", "Transcription success: \(trimmed.prefix(80))...")
                        self.consecutiveFailures = 0

                        let entry = TranscriptionEntry(text: trimmed, duration: duration, model: appState.selectedModelID)
                        appState.addToHistory(entry)

                        TextPaster.shared.pasteText(trimmed)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            self.resetState()
                            appState.setStatus(.idle)
                        }

                    case .failure(let error):
                        logError("HotkeyManager", "Transcription failed: \(error.localizedDescription)")
                        let isTimeout = (error as NSError).code == -4
                        let isFirstRun = appState.selectedModel.modelType == "qwen3"
                        let message = isTimeout && isFirstRun
                            ? "模型首次加载需下载 ~1GB，请稍候几分钟再试（菜单栏显示识别中时请勿关闭 App）"
                            : "识别失败：\(error.localizedDescription)"
                        self.handleFailure(appState: appState, message: message)
                    }
                }
            }

            // Route to correct ASR backend
            if appState.selectedModel.modelType == "macos" {
                logInfo("HotkeyManager", "Using macOS built-in ASR")
                SpeechStreamer.shared.transcribe(audioURL: audioURL, language: language, completion: handleResult)
            } else if appState.selectedModel.modelType == "whisper" {
                let modelID = appState.selectedModel.id
                logInfo("HotkeyManager", "Using WhisperKit. Model: \(modelID)")
                Task {
                    do {
                        let text = try await WhisperService.shared.transcribe(
                            url: audioURL,
                            language: language
                        )
                        handleResult(.success(text))
                    } catch {
                        handleResult(.failure(error))
                    }
                }
            } else {
                let model = appState.selectedModel
                let modelType = model.modelType
                logInfo("HotkeyManager", "Transcribing with \(modelType) model: \(model.repoOrPath.split(separator: "/").last ?? "")")
                Task { [weak self] in
                    guard self != nil else { return }
                    do {
                        let text: String
                        switch modelType {
                        case "qwen3":
                            text = try await ASRService.shared.transcribe(url: audioURL, language: language)
                        case "whisper":
                            text = try await WhisperService.shared.transcribe(url: audioURL, language: language)
                        default:
                            return  // macOS model handled above
                        }
                        await MainActor.run { handleResult(.success(text)) }
                    } catch {
                        await MainActor.run { handleResult(.failure(error)) }
                    }
                }
            }
        }
    }

    private func startModelLiveDraft(modelType: String, language: String?) {
        stopModelLiveDraft()
        liveDraftQueue.sync {
            liveDraftBuffer.removeAll(keepingCapacity: true)
            liveDraftSampleRate = 16000
            liveDraftLastSampleCount = 0
            liveDraftInFlight = false
            liveDraftGeneration &+= 1
        }

        let generation = liveDraftQueue.sync { liveDraftGeneration }
        liveDraftTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.liveDraftMinIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self?.requestModelLiveDraft(
                    modelType: modelType,
                    language: language,
                    generation: generation
                )
            }
        }
    }

    private func stopModelLiveDraft() {
        liveDraftTask?.cancel()
        liveDraftTask = nil
        liveDraftQueue.sync {
            liveDraftGeneration &+= 1
            liveDraftBuffer.removeAll(keepingCapacity: true)
            liveDraftLastSampleCount = 0
            liveDraftInFlight = false
        }
        DispatchQueue.main.async { [weak self] in
            self?.overlay?.updateLiveText("")
        }
    }

    private func appendLiveDraftBuffer(_ buffer: AVAudioPCMBuffer) {
        let sampleRate = Int(buffer.format.sampleRate.rounded())
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard sampleRate > 0, frameCount > 0, channelCount > 0,
              let channelData = buffer.floatChannelData else { return }

        var samples = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            samples.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                base.update(from: channelData[0], count: frameCount)
            }
        } else {
            let divisor = Float(channelCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                samples[frame] = sum / divisor
            }
        }

        liveDraftQueue.async { [weak self] in
            guard let self else { return }
            if self.liveDraftSampleRate != sampleRate {
                self.liveDraftBuffer.removeAll(keepingCapacity: true)
                self.liveDraftLastSampleCount = 0
                self.liveDraftSampleRate = sampleRate
            }

            self.liveDraftBuffer.append(contentsOf: samples)
            let maxSamples = max(1, Int(Self.liveDraftMaxWindowSeconds * Double(sampleRate)))
            if self.liveDraftBuffer.count > maxSamples {
                self.liveDraftBuffer.removeFirst(self.liveDraftBuffer.count - maxSamples)
                self.liveDraftLastSampleCount = min(self.liveDraftLastSampleCount, self.liveDraftBuffer.count)
            }
        }
    }

    private func requestModelLiveDraft(
        modelType: String,
        language: String?,
        generation: UInt64
    ) {
        liveDraftQueue.async { [weak self] in
            guard let self,
                  self.liveDraftGeneration == generation,
                  !self.liveDraftInFlight else { return }

            let minSamples = Int(Self.liveDraftMinIntervalSeconds * Double(self.liveDraftSampleRate))
            let minDelta = Int(Self.liveDraftMinDeltaSeconds * Double(self.liveDraftSampleRate))
            guard self.liveDraftBuffer.count >= minSamples,
                  self.liveDraftBuffer.count - self.liveDraftLastSampleCount >= minDelta else { return }

            let audio = self.liveDraftBuffer
            let sampleRate = self.liveDraftSampleRate
            self.liveDraftLastSampleCount = self.liveDraftBuffer.count
            self.liveDraftInFlight = true

            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let text: String
                    switch modelType {
                    case "qwen3":
                        text = try await ASRService.shared.transcribe(audio: audio, sampleRate: sampleRate, language: language)
                    case "whisper":
                        text = try await WhisperService.shared.transcribe(audio: audio, sampleRate: sampleRate, language: language)
                    default:
                        text = ""
                    }

                    guard let self else { return }
                    let isCurrent = self.liveDraftQueue.sync { self.liveDraftGeneration == generation }
                    guard isCurrent else { return }
                    await MainActor.run {
                        self.overlay?.updateLiveText(text)
                    }
                } catch is CancellationError {
                    // Recording stopped; final transcription path handles the result.
                } catch {
                    logDebug("HotkeyManager", "Live draft failed: \(error.localizedDescription)")
                }

                guard let self else { return }
                nonisolated(unsafe) let manager = self
                manager.liveDraftQueue.async {
                    guard manager.liveDraftGeneration == generation else { return }
                    manager.liveDraftInFlight = false
                }
            }
        }
    }

    private func handleFailure(appState: AppState, message: String) {
        consecutiveFailures += 1
        logWarn("HotkeyManager", "Failure #\(consecutiveFailures): \(message)")

        if consecutiveFailures >= HotkeyManager.maxConsecutiveFailures {
            logError("HotkeyManager", "Too many consecutive failures (\(consecutiveFailures)), performing hard reset")
            AudioRecorder.shared.forceReset()
            consecutiveFailures = 0
        }

        resetState()
        DispatchQueue.main.async {
            appState.setStatus(.idle)
            appState.showError(message)
            self.overlay?.hide()
        }
    }

    private func resetState() {
        lock.lock()
        isRecording = false
        isProcessing = false
        recordingStartTime = nil
        lock.unlock()
    }

    deinit {
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localFlagsMonitor { NSEvent.removeMonitor(monitor) }
        if let ref = lookupHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = translateHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = ocrHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = snipPinHotKeyRef { UnregisterEventHotKey(ref) }
        NotificationCenter.default.removeObserver(self)
    }
}
