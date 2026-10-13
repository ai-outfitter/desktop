import Foundation

enum ModelCatalogState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

protocol ModelFavoritesStorage {
    func loadData(forKey key: String) -> Data?
    func saveData(_ data: Data, forKey key: String)
}

struct UserDefaultsModelFavoritesStorage: ModelFavoritesStorage {
    let defaults: UserDefaults

    func loadData(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func saveData(_ data: Data, forKey key: String) {
        defaults.set(data, forKey: key)
    }
}

struct FileModelFavoritesStorage: ModelFavoritesStorage {
    let fileURL: URL

    static func defaultLocation(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let state = environment["OUTFITTER_DESKTOP_STATE_DIRECTORY"], !state.isEmpty {
            return URL(fileURLWithPath: state).appendingPathComponent("model-favorites.json")
        }
        if let override = environment["PI_NATIVE_TEST_MODEL_FAVORITES_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return applicationSupport.appendingPathComponent("PiNative/model-favorites.json", isDirectory: false)
    }

    func loadData(forKey _: String) -> Data? {
        try? Data(contentsOf: fileURL)
    }

    func saveData(_ data: Data, forKey _: String) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class ModelSettingsModel: ObservableObject {
    @Published private(set) var favorites: [PiModelOption] {
        didSet { persistFavorites() }
    }
    @Published private(set) var catalog: [PiModelOption] = []
    @Published private(set) var catalogState: ModelCatalogState = .idle
    @Published var searchQuery = ""
    private(set) var catalogIsProvisional = false

    private let storage: ModelFavoritesStorage
    private let favoritesKey: String
    private(set) var configuredDefaultModel: PiModelOption?
    private var catalogRefreshTask: Task<Void, Never>?

    init(
        storage: ModelFavoritesStorage = FileModelFavoritesStorage(fileURL: FileModelFavoritesStorage.defaultLocation()),
        favoritesKey: String = "models.favorites",
        configuredDefaultModel: PiModelOption?
    ) {
        self.storage = storage
        self.favoritesKey = favoritesKey
        self.configuredDefaultModel = configuredDefaultModel

        if let data = storage.loadData(forKey: favoritesKey),
           let storedFavorites = try? JSONDecoder().decode([PiModelOption].self, from: data),
           !storedFavorites.isEmpty {
            self.favorites = Self.deduplicatedAndSorted(storedFavorites)
        } else {
            self.favorites = configuredDefaultModel.map { [$0] } ?? []
            persistFavorites()
        }

        if let testCatalog = ProcessInfo.processInfo.environment["PI_NATIVE_TEST_MODEL_CATALOG"],
           let data = testCatalog.data(using: .utf8),
           let models = try? JSONDecoder().decode([PiModelOption].self, from: data) {
            self.updateCatalog(models)
        }

        switch ProcessInfo.processInfo.environment["PI_NATIVE_TEST_MODEL_CATALOG_STATE"] {
        case "loading": catalogState = .loading
        case "empty":
            catalog = []
            catalogState = .loaded
        case "error": catalogState = .failed("Test catalog failure")
        default: break
        }
    }

    var filteredCatalog: [PiModelOption] {
        Self.filter(catalog, query: searchQuery)
    }

    var filteredAvailableFavorites: [PiModelOption] {
        Self.filter(availableFavorites, query: searchQuery)
    }

    var filteredUnavailableFavorites: [PiModelOption] {
        Self.filter(unavailableFavorites, query: searchQuery)
    }

    var filteredOtherModels: [PiModelOption] {
        filteredCatalog.filter { !isFavorite($0) }
    }

    var preferredConversationModel: PiModelOption? {
        availableFavorites.first
    }

    var availableFavorites: [PiModelOption] {
        guard catalogState == .loaded else { return [] }
        let availableIDs = Set(catalog.map(\.stableID))
        return favorites.filter { availableIDs.contains($0.stableID) }
    }

    var unavailableFavorites: [PiModelOption] {
        guard catalogState == .loaded else { return [] }
        let availableIDs = Set(catalog.map(\.stableID))
        return favorites.filter { !availableIDs.contains($0.stableID) }
    }

    func isFavorite(_ model: PiModelOption) -> Bool {
        favorites.contains { $0.stableID == model.stableID }
    }

    func canRemoveFavorite(_ model: PiModelOption) -> Bool {
        !isFavorite(model) || favorites.count > 1
    }

    func setFavorite(_ isFavorite: Bool, for model: PiModelOption) {
        if isFavorite {
            favorites = Self.deduplicatedAndSorted(favorites + [model])
        } else {
            guard canRemoveFavorite(model) else { return }
            favorites = favorites.filter { $0.stableID != model.stableID }
        }
    }

    func removeFavorite(_ model: PiModelOption) {
        setFavorite(false, for: model)
    }

    func refreshCatalogIfNeeded(using client: PiRPCClient) async {
        await refreshCatalogIfNeeded {
            let response = try await client.getAvailableModels(timeoutSeconds: 30)
            return response.data?.objectValue?["models"]?.arrayValue?.compactMap(PiModelOption.init(json:)) ?? []
        }
    }

    func refreshCatalog(using client: PiRPCClient) async {
        await refreshCatalog {
            let response = try await client.getAvailableModels(timeoutSeconds: 30)
            return response.data?.objectValue?["models"]?.arrayValue?.compactMap(PiModelOption.init(json:)) ?? []
        }
    }

    func refreshCatalogIfNeeded(loadModels: @escaping () async throws -> [PiModelOption]) async {
        if let catalogRefreshTask {
            await catalogRefreshTask.value
        }
        guard catalogState != .loaded || catalogIsProvisional else { return }
        await refreshCatalog(loadModels: loadModels)
    }

    func refreshProvisionalCatalogIfNeeded(loadModels: @escaping () async throws -> [PiModelOption]) async {
        if let catalogRefreshTask {
            await catalogRefreshTask.value
        }
        guard catalogState != .loaded else { return }
        await refreshCatalog(loadModels: loadModels, isProvisional: true)
    }

    func refreshProvisionalCatalog(loadModels: @escaping () async throws -> [PiModelOption]) async {
        await refreshCatalog(loadModels: loadModels, isProvisional: true)
    }

    func refreshCatalog(loadModels: @escaping () async throws -> [PiModelOption]) async {
        await refreshCatalog(loadModels: loadModels, isProvisional: false)
    }

    func finishPendingCatalogRefresh() async {
        await catalogRefreshTask?.value
    }

    private func refreshCatalog(
        loadModels: @escaping () async throws -> [PiModelOption],
        isProvisional: Bool
    ) async {
        if let catalogRefreshTask {
            await catalogRefreshTask.value
            return
        }

        catalogState = .loading
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                self.updateCatalog(try await loadModels(), isProvisional: isProvisional)
            } catch {
                self.failCatalog(error.localizedDescription)
            }
            self.catalogRefreshTask = nil
        }
        catalogRefreshTask = task
        await task.value
    }

    func updateCatalog(_ models: [PiModelOption], isProvisional: Bool = false) {
        catalog = Self.deduplicatedAndSorted(models)
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.stableID, $0) })
        favorites = favorites.map { favorite in
            catalogByID[favorite.stableID] ?? favorite
        }
        catalogIsProvisional = isProvisional
        catalogState = .loaded
    }

    func failCatalog(_ message: String) {
        catalogState = .failed(message)
    }

    func markCatalogStale() {
        catalogState = .idle
    }

    static func filter(_ models: [PiModelOption], query: String) -> [PiModelOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return models }
        return models.filter { model in
            model.provider.lowercased().contains(needle)
                || model.id.lowercased().contains(needle)
                || model.name.lowercased().contains(needle)
        }
    }

    static func deduplicatedAndSorted(_ models: [PiModelOption]) -> [PiModelOption] {
        var seen = Set<String>()
        return models
            .filter { seen.insert($0.stableID).inserted }
            .sorted {
                ($0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedSame
                    ? $0.name.localizedCaseInsensitiveCompare($1.name)
                    : $0.provider.localizedCaseInsensitiveCompare($1.provider)) == .orderedAscending
            }
    }

    private func persistFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        storage.saveData(data, forKey: favoritesKey)
    }

    static func configuredDefaultModel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> PiModelOption? {
        if let provider = environment["PI_NATIVE_TEST_DEFAULT_PROVIDER"],
           let modelID = environment["PI_NATIVE_TEST_DEFAULT_MODEL"] {
            return PiModelOption(provider: provider, id: modelID, name: modelID)
        }
        let agentDirectory = environment["PI_CODING_AGENT_DIR"] ?? NSHomeDirectory() + "/.pi/agent"
        let settingsURL = URL(fileURLWithPath: agentDirectory).appendingPathComponent("settings.json")
        guard let data = fileManager.contents(atPath: settingsURL.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = object["defaultProvider"] as? String,
              let modelID = object["defaultModel"] as? String,
              !provider.isEmpty,
              !modelID.isEmpty
        else { return nil }
        return PiModelOption(provider: provider, id: modelID, name: modelID)
    }
}
