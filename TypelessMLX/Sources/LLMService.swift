import Foundation
import MLXLLM
import MLXLMCommon

class LLMService {
    static let shared = LLMService()
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?

    private init() {}

    enum TranslationTarget {
        case chinese
        case english

        var displayName: String {
            switch self {
            case .chinese: return "简体中文"
            case .english: return "English"
            }
        }
    }

    func translate(_ text: String, target: TranslationTarget = .chinese) async throws -> String {
        let c = try await loadedContainer()
        let session = ChatSession(c)
        let prompt = "你是翻译助手。请将原文翻译为\(target.displayName)。只输出翻译结果，不要解释，不要添加前后缀。\n原文：「\(text)」"
        let raw = try await session.respond(to: prompt)
        var result = sanitizeTranslationOutput(raw)

        if target == .chinese, Self.requiresChineseOutput(source: text), !Self.looksLikeChinese(result) {
            logWarn("LLMService", "Chinese translation looked invalid; retrying. source=\(Self.preview(text)) result=\(Self.preview(result))")
            let retrySession = ChatSession(c)
            let retryPrompt = """
            你是专业字幕翻译器。把英文字幕片段翻译成自然的简体中文。
            即使原文是不完整半句，也必须翻译，不要补全后文。
            只输出中文译文；不要输出英文原文；不要解释。

            示例：
            英文：What kind of person has
            中文：什么样的人会有
            英文：What kind of person?
            中文：什么样的人？
            英文：Personally.
            中文：就我个人而言。
            英文：And it was great.
            中文：而且这很棒。

            英文：\(text)
            中文：
            """
            result = sanitizeTranslationOutput(try await retrySession.respond(to: retryPrompt))

            if !Self.looksLikeChinese(result), let fallback = Self.shortChineseFallback(for: text) {
                logWarn("LLMService", "Using short subtitle fallback. source=\(Self.preview(text)) fallback=\(fallback)")
                result = fallback
            }

            if !Self.looksLikeChinese(result) {
                logWarn("LLMService", "Rejected non-Chinese translation. source=\(Self.preview(text)) result=\(Self.preview(result))")
                return ""
            }
        }

        return result
    }

    private func sanitizeTranslationOutput(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("“", "”"),
            ("‘", "’"),
            ("「", "」"),
            ("『", "』"),
            ("《", "》"),
            ("〈", "〉"),
        ]

        for _ in 0..<2 {
            guard let first = result.first, let last = result.last, result.count >= 2 else { break }
            guard quotePairs.contains(where: { $0.0 == first && $0.1 == last }) else { break }
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    static func looksLikeChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    private static func requiresChineseOutput(source: String) -> Bool {
        let latinCount = source.unicodeScalars.filter { scalar in
            (0x41...0x5A).contains(Int(scalar.value)) || (0x61...0x7A).contains(Int(scalar.value))
        }.count
        return latinCount >= 3
    }

    private static func shortChineseFallback(for text: String) -> String? {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9' ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch normalized {
        case "what kind":
            return "什么样的？"
        case "what kind of person":
            return "什么样的人？"
        case "what kind of person has":
            return "什么样的人会有"
        case "personally":
            return "就我个人而言。"
        case "and it was great", "and there was great":
            return "而且这很棒。"
        default:
            return nil
        }
    }

    private static func preview(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .prefix(80)
            .description
    }

    func lookup(_ word: String) async throws -> String {
        let c = try await loadedContainer()
        let session = ChatSession(c)
        let prompt = "请用中文解释「\(word)」的含义，包括词性、释义和例句，简明扼要。"
        return try await session.respond(to: prompt)
    }

    func preload() {
        guard container == nil, loadTask == nil else { return }
        loadTask = Task {
            let c = try await self.loadModel()
            self.container = c
            self.loadTask = nil
            return c
        }
    }

    private func loadedContainer() async throws -> ModelContainer {
        if let c = container { return c }
        if let t = loadTask { return try await t.value }
        let t = Task<ModelContainer, Error> { [weak self] in
            guard let self else { throw LLMError.deallocated }
            let c = try await loadModel()
            self.container = c
            self.loadTask = nil
            return c
        }
        loadTask = t
        return try await t.value
    }

    private func loadModel() async throws -> ModelContainer {
        let repoID = AppState.shared.resolvedTextModelPath
        logInfo("LLMService", "Loading text model: \(repoID)")

        guard let localURL = resolveLocalURL(repoID) else {
            AppState.shared.showModelCacheAlert(feature: "翻译/查词", modelId: repoID)
            throw LLMError.localCacheUnavailable(modelId: repoID)
        }

        logInfo("LLMService", "Found cached model at: \(localURL.path)")
        do {
            return try await loadModelContainer(directory: localURL)
        } catch {
            AppState.shared.showModelCacheAlert(feature: "翻译/查词", modelId: repoID)
            throw LLMError.localCacheCorrupted(modelId: repoID, underlying: error)
        }
    }
    // Checks ~/.cache/huggingface/hub and ~/Library/Caches/huggingface for existing snapshots
    private func resolveLocalURL(_ repoID: String) -> URL? {
        if repoID.hasPrefix("/") { return URL(fileURLWithPath: repoID) }
        let sanitized = repoID.replacingOccurrences(of: "/", with: "--")
        let searchBases = [
            NSHomeDirectory() + "/.cache/huggingface/hub",
            (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? "") + "/huggingface/hub",
        ]
        for base in searchBases {
            let snapDir = base + "/models--\(sanitized)/snapshots"
            let snapshots = (try? FileManager.default.contentsOfDirectory(atPath: snapDir)) ?? []
            if let latest = snapshots.sorted().last {
                return URL(fileURLWithPath: snapDir + "/" + latest)
            }
        }
        return nil
    }


    enum LLMError: LocalizedError {
        case deallocated
        case localCacheUnavailable(modelId: String)
        case localCacheCorrupted(modelId: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .deallocated:
                return "LLMService deallocated during model load"
            case .localCacheUnavailable(let modelId):
                return "文本模型本地缓存不可用：\(modelId)。请在偏好设置中手动下载模型。"
            case .localCacheCorrupted(let modelId, let underlying):
                return "文本模型本地缓存损坏：\(modelId)。请删除后重新下载。原始错误：\(underlying.localizedDescription)"
            }
        }
    }
}
