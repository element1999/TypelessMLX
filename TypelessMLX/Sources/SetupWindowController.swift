import AppKit
import SwiftUI

class SetupWindowController: NSObject {
    static let shared = SetupWindowController()

    private var window: NSWindow?
    private var viewModel: SetupViewModel?

    func show(onComplete: (() -> Void)? = nil) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = SetupViewModel(onComplete: onComplete)
        self.viewModel = vm

        let contentView = SetupView(viewModel: vm)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 420)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TypelessMLX 设置"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        vm.checkAll()
    }

    func close() {
        window?.close()
        window = nil
        viewModel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - ViewModel

class SetupViewModel: ObservableObject {
    enum StepStatus { case unknown, running, done, failed(String) }

    @Published var venvStatus: StepStatus = .unknown
    @Published var logLines: [String] = []
    @Published var isRunning = false
    @Published var allDone = false

    private var onComplete: (() -> Void)?

    init(onComplete: (() -> Void)? = nil) {
        self.onComplete = onComplete
    }

    func checkAll() {
        DispatchQueue.main.async {
            self.venvStatus = WhisperBridge.isVenvReady() ? .done : .unknown
            self.updateAllDone()
        }
    }

    func runSetup() {
        guard !isRunning else { return }
        isRunning = true
        logLines.removeAll()

        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: Create Python venv
            if !WhisperBridge.isVenvReady() {
                DispatchQueue.main.async { self.venvStatus = .running }
                self.appendLog("🔧 创建 Python 虚拟环境...")
                let installed = self.createVenv()
                if installed {
                    self.appendLog("✅ Python 虚拟环境创建完成")
                    DispatchQueue.main.async { self.venvStatus = .done }
                } else {
                    self.appendLog("❌ Python 虚拟环境创建失败，请确认已安装 uv")
                    DispatchQueue.main.async { self.venvStatus = .failed("安装失败") }
                    DispatchQueue.main.async { self.isRunning = false }
                    return
                }
            } else {
                self.appendLog("✅ Python 虚拟环境已存在")
            }

            self.appendLog("")
            self.appendLog("🎉 设置完成！按 Right Option 开始录音。")

            DispatchQueue.main.async {
                self.isRunning = false
                self.updateAllDone()
                // Start WhisperBridge
                WhisperBridge.shared.start { success in
                    AppState.shared.hasPythonBackend = success
                    AppState.shared.updatePermissionState()
                    logInfo("Setup", "WhisperBridge start: \(success)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.onComplete?()
                    SetupWindowController.shared.close()
                }
            }
        }
    }

    private func createVenv() -> Bool {
        let venvPath = NSHomeDirectory() + "/.local/share/typelessmlx/venv"
        let requirementsPath = findRequirementsPath()

        var env = WhisperBridge.makeEnv()
        let certPath = AppState.shared.customCACertPath.trimmingCharacters(in: .whitespaces)
        let expandedCert = certPath.isEmpty ? "" : (certPath as NSString).expandingTildeInPath
        if !expandedCert.isEmpty {
            env["SSL_CERT_FILE"] = expandedCert
            env["REQUESTS_CA_BUNDLE"] = expandedCert
        }

        // Prefer a local Python 3.12 — avoids any uv network call (uv uses rustls which
        // ignores SSL_CERT_FILE and custom CA certs on corporate networks).
        if let python312 = findLocalPython312() {
            appendLog("   找到本地 Python 3.12: \(python312)")
            appendLog("   创建虚拟环境...")
            guard runCommand(python312, args: ["-m", "venv", venvPath, "--clear"], env: env) else {
                appendLog("   ❌ 创建 venv 失败")
                return false
            }
            appendLog("   安装 Python 包...")
            return runCommand(venvPath + "/bin/pip",
                              args: ["install", "-r", requirementsPath ?? "requirements.txt"],
                              env: env)
        }

        // No local Python 3.12 found — fall back to uv (requires network)
        guard let uvPath = findUv() else {
            appendLog("   ❌ 未找到 uv 且无本地 Python 3.12")
            appendLog("   请安装：brew install python@3.12  或  https://docs.astral.sh/uv/")
            return false
        }
        appendLog("   未找到本地 Python 3.12，使用 uv 下载...")
        appendLog("   ⚠️  若证书报错，请先执行：brew install python@3.12")
        guard runCommand(uvPath,
                         args: ["venv", venvPath, "--python", "3.12", "--clear", "--system-certs"],
                         env: env) else {
            appendLog("   ❌ 创建 venv 失败")
            return false
        }
        appendLog("   安装 Python 包...")
        return runCommand(venvPath + "/bin/pip",
                          args: ["install", "-r", requirementsPath ?? "requirements.txt"],
                          env: env)
    }

    private func findLocalPython312() -> String? {
        let fm = FileManager.default
        // uv-managed Python cache
        let uvCache = NSHomeDirectory() + "/.local/share/uv/python"
        if let entries = try? fm.contentsOfDirectory(atPath: uvCache) {
            for entry in entries.sorted().reversed() where entry.contains("cpython-3.12") {
                let bin = uvCache + "/\(entry)/bin/python3.12"
                if fm.fileExists(atPath: bin) { return bin }
            }
        }
        // Homebrew / system
        for path in ["/opt/homebrew/bin/python3.12", "/usr/local/bin/python3.12"] {
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private func findUv() -> String? {
        let env = WhisperBridge.makeEnv()
        let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv",
                          NSHomeDirectory() + "/.local/bin/uv",
                          NSHomeDirectory() + "/.cargo/bin/uv"]
            + (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/uv" }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func findRequirementsPath() -> String? {
        if let bundlePath = Bundle.main.path(forResource: "requirements", ofType: "txt", inDirectory: "backend") {
            return bundlePath
        }
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend/requirements.txt").path
        return FileManager.default.fileExists(atPath: devPath) ? devPath : nil
    }

    private func runCommand(_ executable: String, args: [String], env: [String: String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for line in lines { self?.appendLog("   \(line)") }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for line in lines { self?.appendLog("   \(line)") }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return process.terminationStatus == 0
        } catch {
            appendLog("   执行失败: \(error)")
            return false
        }
    }

    private func updateAllDone() {
        if case .done = venvStatus {
            allDone = true
        } else {
            allDone = false
        }
    }

    func appendLog(_ line: String) {
        if Thread.isMainThread {
            logLines.append(line)
        } else {
            DispatchQueue.main.async { self.logLines.append(line) }
        }
    }
}

// MARK: - SwiftUI View

struct SetupView: View {
    @ObservedObject var viewModel: SetupViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TypelessMLX 设置")
                        .font(.title2.bold())
                    Text("配置 Python 环境（语音模型在首次使用时自动下载）")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)

            // Steps
            VStack(spacing: 8) {
                stepRow(icon: "python.circle.fill",
                        title: "Python 虚拟环境",
                        subtitle: "安装 mlx-whisper 及依赖包",
                        status: viewModel.venvStatus)
            }
            .padding(.horizontal)

            // Log
            VStack(alignment: .leading, spacing: 4) {
                Text("安装日志")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(logColor(for: line))
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 160)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                    .onChange(of: viewModel.logLines.count) { _ in
                        if let last = viewModel.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal)

            // Buttons
            HStack {
                Button("重新检查") { viewModel.checkAll() }
                    .disabled(viewModel.isRunning)

                Spacer()

                if viewModel.isRunning {
                    ProgressView().controlSize(.small).padding(.trailing, 8)
                }

                Button("开始安装") { viewModel.runSetup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isRunning)

                Button("关闭") { SetupWindowController.shared.close() }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private func stepRow(icon: String, title: String, subtitle: String, status: SetupViewModel.StepStatus) -> some View {
        HStack(spacing: 12) {
            statusIcon(status: status).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.bold())
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            statusLabel(status: status)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private func statusIcon(status: SetupViewModel.StepStatus) -> some View {
        switch status {
        case .unknown: Image(systemName: "circle.dashed").foregroundColor(.gray)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private func statusLabel(status: SetupViewModel.StepStatus) -> some View {
        switch status {
        case .unknown: Text("未检查").font(.caption).foregroundColor(.gray)
        case .running: Text("进行中...").font(.caption).foregroundColor(.orange)
        case .done: Text("完成").font(.caption).foregroundColor(.green)
        case .failed(let msg): Text("失败").font(.caption).foregroundColor(.red).help(msg)
        }
    }

    private func logColor(for line: String) -> Color {
        if line.contains("✅") || line.contains("🎉") { return .green }
        if line.contains("❌") { return .red }
        if line.contains("⚠️") || line.contains("失败") { return .orange }
        if line.contains("🔧") || line.contains("🔄") { return .blue }
        return .primary
    }
}
