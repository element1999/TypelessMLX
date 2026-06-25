import Foundation
import MLXLLM
import MLXLMCommon

/// Native MLXLLM-based service for translation and word lookup.
/// Must run on MainActor — MLX Metal operations require main-thread context.
@MainActor
class LLMService {

    static let shared = LLMService()

    private var container: ModelContainer?
    private var loadedModelPath: String?

    private init() {}

    // MARK: - Public API

    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let container = try await loadModelIfNeeded()
        let isCJK = cjkRatio(trimmed) > 0.3

        let messages: [Chat.Message]
        if isCJK {
            messages = [
                .system("You are a translator. Translate the Chinese text to natural, fluent English. Output only the translation."),
                .user("「\(trimmed)」"),
            ]
        } else {
            messages = [.user("将以下英文翻译成简体中文，只输出中文译文，不要输出英文：\n「\(trimmed)」")]
        }

        let result = try await generate(container: container, messages: messages, maxTokens: 300)

        let ratio = cjkRatio(result)
        if isCJK && ratio > 0.3 {
            logWarn("LLMService", "ZH→EN validation failed (CJK ratio \(String(format:"%.2f",ratio)))")
            return ""
        }
        if !isCJK && ratio < 0.1 {
            logWarn("LLMService", "EN→ZH validation failed (CJK ratio \(String(format:"%.2f",ratio)))")
            return ""
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func lookup(_ word: String) async throws -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let container = try await loadModelIfNeeded()
        let prompt = "你是英汉词典，只输出2行，不多不少。格式：\n第1行: [词性] [中文核心含义，不超过8字]\n第2行: 例: [英文短句] → [中文]\n\n单词：「\(trimmed)」"
        let result = try await generate(container: container, messages: [.user(prompt)], maxTokens: 100)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Model Loading

    private func loadModelIfNeeded() async throws -> ModelContainer {
        let modelPath = AppState.shared.resolvedTextModelPath

        if let c = container, loadedModelPath == modelPath { return c }

        container = nil
        loadedModelPath = nil
        logInfo("LLMService", "Loading text model: \(modelPath)")

        let localPath = resolveLocalSnapshotPath(for: modelPath)
        let configuration: ModelConfiguration
        if localPath != modelPath {
            logInfo("LLMService", "Using local snapshot: \(localPath)")
            configuration = ModelConfiguration(directory: URL(fileURLWithPath: localPath))
        } else {
            configuration = ModelConfiguration(id: modelPath)
        }

        let newContainer = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
        container = newContainer
        loadedModelPath = modelPath
        logInfo("LLMService", "Text model loaded")
        return newContainer
    }

    private func resolveLocalSnapshotPath(for repoID: String) -> String {
        guard !repoID.hasPrefix("/") else { return repoID }
        let sanitized = repoID.replacingOccurrences(of: "/", with: "--")
        let cacheBase = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cache/huggingface/hub/models--\(sanitized)/snapshots")
        let snapshots = (try? FileManager.default.contentsOfDirectory(atPath: cacheBase)) ?? []
        guard let latest = snapshots.sorted().last else { return repoID }
        return (cacheBase as NSString).appendingPathComponent(latest)
    }

    // MARK: - Generation

    private func generate(container: ModelContainer, messages: [Chat.Message], maxTokens: Int) async throws -> String {
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0)
        return try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(chat: messages))
            let result: GenerateResult = try MLXLMCommon.generate(
                input: input, parameters: params, context: context
            ) { (_: [Int]) in .more }
            return result.output
        }
    }

    // MARK: - Language Detection

    private func cjkRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let cjk = text.unicodeScalars.filter {
            let v = $0.value
            return (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF)
                || (v >= 0xF900 && v <= 0xFAFF) || (v >= 0x2E80 && v <= 0x2EFF)
        }.count
        return Double(cjk) / Double(max(text.unicodeScalars.count, 1))
    }
}
