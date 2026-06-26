import Foundation
import Hub
import MLXLLM
import MLXLMCommon

class LLMService {
    static let shared = LLMService()
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?

    private init() {}

    func translate(_ text: String) async throws -> String {
        let c = try await loadedContainer()
        let session = ChatSession(c)
        let prompt = "你是翻译助手。将下面的内容翻译为中文，如果原文已经是中文则翻译为英文。直接输出翻译结果，不要解释。\n原文：「\(text)」"
        return try await session.respond(to: prompt)
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
        // Check standard HF cache paths first (compatible with Python-downloaded models)
        if let localURL = resolveLocalURL(repoID) {
            logInfo("LLMService", "Found cached model at: \(localURL.path)")
            return try await loadModelContainer(directory: localURL)
        }
        // Download via HF, storing in ~/.cache/huggingface to match Python convention
        logInfo("LLMService", "Model not cached, downloading: \(repoID)")
        let hub = makeHubApi()
        return try await loadModelContainer(hub: hub, id: repoID)
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

    private func makeHubApi() -> HubApi {
        // Store in ~/.cache/huggingface to match Python huggingface_hub convention
        let cacheBase = URL(fileURLWithPath: NSHomeDirectory() + "/.cache/huggingface")
        let endpoint = ProcessInfo.processInfo.environment["HF_ENDPOINT"] ?? "https://hf-mirror.com"
        return HubApi(downloadBase: cacheBase, endpoint: endpoint)
    }

    enum LLMError: LocalizedError {
        case deallocated
        var errorDescription: String? { "LLMService deallocated during model load" }
    }
}
