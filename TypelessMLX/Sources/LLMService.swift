import Foundation
import MLXLLM
import MLXLMCommon

/// Native MLXLLM-based service for translation and word lookup.
/// Lazy-loads the model on first call and reloads if the model path changes.
actor LLMService {

    static let shared = LLMService()

    private var container: ModelContainer?
    private var loadedModelPath: String?

    private init() {}

    // MARK: - Public API

    /// Translate text bidirectionally between English and Chinese.
    /// CJK ratio > 30% → ZH→EN, else EN→ZH.
    /// Returns "" if the output fails validation.
    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let container = try await loadModelIfNeeded()
        let isCJK = cjkRatio(trimmed) > 0.3

        let messages: [Chat.Message]
        if isCJK {
            // ZH→EN
            messages = [
                .system(
                    "You are a translator. Translate the Chinese text to natural, fluent English. Output only the translation."
                ),
                .user("「\(trimmed)」"),
            ]
        } else {
            // EN→ZH
            messages = [
                .user("将以下英文翻译成简体中文，只输出中文译文，不要输出英文：\n「\(trimmed)」")
            ]
        }

        let result = try await generate(container: container, messages: messages, maxTokens: 300)

        // Validate: EN→ZH must contain CJK chars; ZH→EN must be mostly non-CJK
        let ratio = cjkRatio(result)
        if isCJK {
            if ratio > 0.3 {
                logWarn("LLMService", "ZH→EN validation failed: CJK ratio \(ratio) in output")
                return ""
            }
        } else {
            if ratio < 0.1 {
                logWarn("LLMService", "EN→ZH validation failed: CJK ratio \(ratio) in output")
                return ""
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Look up a word and return a 2-line dictionary entry.
    func lookup(_ word: String) async throws -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let container = try await loadModelIfNeeded()
        let prompt =
            "你是英汉词典，只输出2行，不多不少。格式：\n第1行: [词性] [中文核心含义，不超过8字]\n第2行: 例: [英文短句] → [中文]\n\n单词：「\(trimmed)」"
        let messages: [Chat.Message] = [.user(prompt)]
        let result = try await generate(container: container, messages: messages, maxTokens: 100)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Model Loading

    private func loadModelIfNeeded() async throws -> ModelContainer {
        let modelPath = AppState.shared.resolvedTextModelPath

        if let c = container, loadedModelPath == modelPath {
            return c
        }

        // Release previous model before loading new one
        container = nil
        loadedModelPath = nil

        logInfo("LLMService", "Loading text model: \(modelPath)")

        let configuration = ModelConfiguration(id: modelPath)
        let newContainer = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration)

        container = newContainer
        loadedModelPath = modelPath
        logInfo("LLMService", "Text model loaded: \(modelPath)")
        return newContainer
    }

    // MARK: - Generation

    private func generate(
        container: ModelContainer, messages: [Chat.Message], maxTokens: Int
    ) async throws -> String {
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0)

        return try await container.perform { context in
            let userInput = UserInput(chat: messages)
            let input = try await context.processor.prepare(input: userInput)
            let result: GenerateResult = try MLXLMCommon.generate(
                input: input, parameters: params, context: context
            ) { (_: [Int]) in .more }
            return result.output
        }
    }

    // MARK: - Language Detection

    private func cjkRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let total = text.unicodeScalars.count
        guard total > 0 else { return 0 }
        let cjkCount = text.unicodeScalars.filter { isCJKScalar($0) }.count
        return Double(cjkCount) / Double(total)
    }

    private func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF)   // CJK Unified Ideographs
            || (v >= 0x3400 && v <= 0x4DBF)   // CJK Extension A
            || (v >= 0x20000 && v <= 0x2A6DF) // CJK Extension B
            || (v >= 0xF900 && v <= 0xFAFF)   // CJK Compatibility Ideographs
            || (v >= 0x2E80 && v <= 0x2EFF)   // CJK Radicals Supplement
            || (v >= 0x3000 && v <= 0x303F)   // CJK Symbols and Punctuation
    }
}
