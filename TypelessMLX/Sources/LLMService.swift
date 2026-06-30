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
        return sanitizeTranslationOutput(raw)
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
