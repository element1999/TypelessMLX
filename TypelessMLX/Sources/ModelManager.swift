import Foundation
import HuggingFace

/// Manages on-disk cache for MLX models (HuggingFace Hub + local converted models).
class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var downloadingModelID: String?
    @Published var downloadStatusText: String = ""     // e.g. "下載中 7/11 個檔案..."
    @Published var downloadError: String? = nil
    @Published var cachedSizes: [String: Int64] = [:]  // modelID → bytes, 0 = not cached

    private var downloadTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.typelessmlx.modelmanager", qos: .utility)

    private init() {
        // Warm cache sizes asynchronously to avoid blocking first-time Settings open.
        refreshAllStatuses()
    }

    // MARK: - Cache Status

    func refreshAllStatuses() {
        queue.async { [weak self] in
            guard let self = self else { return }
            var sizes: [String: Int64] = [:]
            for model in AppState.downloadableModels {
                sizes[model.id] = self.diskSize(for: model)
            }
            DispatchQueue.main.async { self.cachedSizes = sizes }
        }
    }

    func isCached(_ model: MLXModel) -> Bool {
        if AppState.bundledModelPath(for: model) != nil { return true }
        return (cachedSizes[model.id] ?? 0) > 0
    }

    func isSelectable(_ model: MLXModel) -> Bool {
        model.isLocal || isCached(model)
    }

    /// Human-readable size string, e.g. "1.2 GB"
    func sizeString(for model: MLXModel) -> String {
        let bytes = cachedSizes[model.id] ?? 0
        guard bytes > 0 else { return "" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 0.1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Download

    func download(_ model: MLXModel) {
        guard downloadingModelID == nil else { return }
        guard !model.isLocal else { return }  // local models don't need downloading

        DispatchQueue.main.async {
            self.downloadingModelID = model.id
            self.downloadStatusText = "连接中..."
            self.downloadError = nil
        }
        logInfo("ModelManager", "Starting download: \(model.repoOrPath)")

        downloadTask = Task { [weak self] in
            guard let self = self else { return }
            var success = false
            do {
                let repo = try Self.repoID(from: model.repoOrPath)
                let client = Self.hubClient()
                let matching = Self.matchingGlobs(for: model)
                _ = try await client.downloadSnapshot(
                    of: repo,
                    matching: matching,
                    maxConcurrentDownloads: 4
                ) { [weak self] progress in
                    self?.downloadStatusText = Self.progressText(progress)
                }
                success = true
            } catch {
                if Task.isCancelled { return }
                if self.hasCachedWhisperKitCoreMLModel(model) {
                    success = true
                    logWarn("ModelManager", "Download returned an error, but required WhisperKit CoreML files are present; treating as cached: \(model.id). Error: \(error)")
                } else {
                    logError("ModelManager", "Download error: \(error)")
                }
            }

            logInfo("ModelManager", "Download \(success ? "succeeded" : "failed") for \(model.id)")

            // Compute disk size on background thread to avoid blocking main thread
            let size = self.diskSize(for: model)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.downloadingModelID = nil
                self.downloadStatusText = ""
                self.downloadTask = nil
                self.cachedSizes[model.id] = size
                self.downloadError = success ? nil : "下载失败：\(model.id)"
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        DispatchQueue.main.async {
            self.downloadingModelID = nil
            self.downloadError = nil
        }
    }

    // MARK: - Delete

    func delete(_ model: MLXModel) throws {
        for cacheURL in cacheDirectories(for: model) {
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                try FileManager.default.removeItem(at: cacheURL)
                logInfo("ModelManager", "Deleted cache: \(cacheURL.lastPathComponent)")
            }
        }
        DispatchQueue.main.async { self.cachedSizes[model.id] = 0 }
    }

    // MARK: - HuggingFace downloads

    private static func repoID(from value: String) throws -> Repo.ID {
        guard let repo = Repo.ID(rawValue: value) else {
            throw NSError(domain: "ModelManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HuggingFace repo: \(value)"])
        }
        return repo
    }

    private static func hubClient() -> HubClient {
        let cache = HubCache(cacheDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub"))
        let hostString = ProcessInfo.processInfo.environment["HF_ENDPOINT"] ?? "https://hf-mirror.com"
        let host = URL(string: hostString) ?? HubClient.defaultHost
        return HubClient(host: host, userAgent: "TypelessMLX", cache: cache)
    }

    private static func matchingGlobs(for model: MLXModel) -> [String] {
        guard model.modelType == "whisper", let variant = AppState.whisperKitVariant(for: model.id) else {
            return []
        }
        return WhisperService.requiredWhisperKitDownloadFiles(for: variant).map { "\(variant)/\($0)" }
    }

    private static func progressText(_ progress: Progress) -> String {
        let completed = progress.completedUnitCount
        let total = progress.totalUnitCount
        if total > 0 {
            let percent = Int((Double(completed) / Double(total)) * 100)
            return "下载中 \(percent)%..."
        }
        return "下载中..."
    }

    // MARK: - Paths

    /// Returns the primary cache directory for the model (nil if not applicable).
    private func cacheDirectory(for model: MLXModel) -> URL? {
        cacheDirectories(for: model).first
    }

    /// Returns all possible cache roots for the model.
    private func cacheDirectories(for model: MLXModel) -> [URL] {
        if model.isLocal {
            if model.repoOrPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return []
            }
            return [URL(fileURLWithPath: model.repoOrPath)]
        }

        let sanitized = model.repoOrPath.replacingOccurrences(of: "/", with: "--")
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".cache/huggingface/hub/models--\(sanitized)"),
            home.appendingPathComponent("Library/Caches/huggingface/hub/models--\(sanitized)")
        ]
    }

    private func cachedWhisperKitModelFolder(for model: MLXModel) -> URL? {
        guard model.modelType == "whisper",
              let variant = AppState.whisperKitVariant(for: model.id) else { return nil }

        var candidates: [URL] = []
        for dir in cacheDirectories(for: model) {
            let snapshots = dir.appendingPathComponent("snapshots")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { continue }

            let found = names
                .map { snapshots.appendingPathComponent($0).appendingPathComponent(variant) }
                .filter { WhisperService.hasWhisperKitCoreMLFiles(in: $0) }
            candidates.append(contentsOf: found)
        }

        return candidates.max { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate < rDate
        }
    }

    private func hasCachedWhisperKitCoreMLModel(_ model: MLXModel) -> Bool {
        cachedWhisperKitModelFolder(for: model) != nil
    }

    private func diskSize(for model: MLXModel) -> Int64 {
        if model.isLocal {
            guard let dir = cacheDirectory(for: model) else { return 0 }
            guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
            return directorySize(dir)
        }

        let dirs = cacheDirectories(for: model)
        guard !dirs.isEmpty else { return 0 }

        if model.modelType == "whisper", let variant = AppState.whisperKitVariant(for: model.id) {
            var best: Int64 = 0
            for dir in dirs {
                let snapshots = dir.appendingPathComponent("snapshots")
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { continue }
                let size = names.reduce(Int64(0)) { total, name in
                    let variantDir = snapshots.appendingPathComponent(name).appendingPathComponent(variant)
                    guard FileManager.default.fileExists(atPath: variantDir.path) else { return total }
                    return max(total, directorySize(variantDir))
                }
                best = max(best, size)
            }
            return best > 1024 ? best : 0
        }

        // Prefer Hub blobs/ when present.
        var bestBlobSize: Int64 = 0
        for dir in dirs {
            let blobs = dir.appendingPathComponent("blobs")
            guard FileManager.default.fileExists(atPath: blobs.path) else { continue }
            bestBlobSize = max(bestBlobSize, directorySize(blobs))
        }
        if bestBlobSize > 1024 { return bestBlobSize }

        // Offline model zips install real files directly under snapshots/ (not symlinks to blobs).
        var bestSnapshotSize: Int64 = 0
        for dir in dirs {
            let snapshots = dir.appendingPathComponent("snapshots")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { continue }
            for name in names {
                let snapshotDir = snapshots.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: snapshotDir.path) else { continue }
                bestSnapshotSize = max(bestSnapshotSize, directorySize(snapshotDir))
            }
        }
        return bestSnapshotSize > 1024 ? bestSnapshotSize : 0
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += fileSizeFollowingSymlink(fileURL)
        }
        return total
    }

    private func fileSizeFollowingSymlink(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true,
           let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            let resolved = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
            let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Int64(size)
        }
        return Int64(values?.fileSize ?? 0)
    }
}
