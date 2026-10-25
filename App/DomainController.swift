import AppKit
import BlueDuckKit
import FileProvider

/// Owns the list of configured buckets and keeps File Provider domains in sync with it.
@MainActor
final class DomainController: ObservableObject {
    @Published private(set) var configs: [DomainConfig] = []
    @Published var lastError: String?

    private var refreshTimer: Timer?

    init() {
        configs = ConfigStore.load()
        Task { await registerMissingDomains() }
        // S3 has no change notifications; poll for remote changes while the app runs.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func secret(for config: DomainConfig) -> String {
        CredentialStore.secret(for: config.id) ?? ""
    }

    /// Creates or updates a bucket. Changing where it points resets the local replica.
    func save(_ config: DomainConfig, secret: String) async {
        do {
            try validate(config, secret: secret)
            let previous = configs.first { $0.id == config.id }
            try CredentialStore.setSecret(secret, for: config.id)
            var updated = configs.filter { $0.id != config.id }
            updated.append(config)
            updated.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            try ConfigStore.save(updated)
            configs = updated

            let domain = Self.domain(for: config)
            if let previous, Self.locationChanged(previous, config) {
                try await NSFileProviderManager.remove(domain)
                removeState(for: config.id)
            }
            try await NSFileProviderManager.add(domain)
            refresh(config)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func remove(_ config: DomainConfig) async {
        do {
            try await NSFileProviderManager.remove(Self.domain(for: config))
        } catch {
            lastError = error.localizedDescription
        }
        CredentialStore.deleteSecret(for: config.id)
        removeState(for: config.id)
        configs.removeAll { $0.id == config.id }
        try? ConfigStore.save(configs)
    }

    /// Checks that the bucket can be listed with the given credentials.
    func testConnection(_ config: DomainConfig, secret: String) async -> String {
        do {
            try validate(config, secret: secret)
            _ = try await config.makeClient(secret: secret).listPage(prefix: config.normalizedRootPrefix, delimiter: "/", maxKeys: 1)
            return "Connected to \(config.bucket)."
        } catch {
            return "Connection failed: \(error.localizedDescription)"
        }
    }

    func revealInFinder(_ config: DomainConfig) async {
        guard let manager = NSFileProviderManager(for: Self.domain(for: config)) else { return }
        do {
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            NSWorkspace.shared.open(url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Asks the extension to check S3 for changes.
    func refresh(_ config: DomainConfig) {
        NSFileProviderManager(for: Self.domain(for: config))?.signalEnumerator(for: .workingSet) { _ in }
    }

    func refreshAll() {
        configs.forEach(refresh)
    }

    // MARK: - Private

    private func registerMissingDomains() async {
        let existing = (try? await NSFileProviderManager.domains()) ?? []
        let ids = Set(existing.map(\.identifier.rawValue))
        for config in configs where !ids.contains(config.id) {
            do {
                try await NSFileProviderManager.add(Self.domain(for: config))
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func validate(_ config: DomainConfig, secret: String) throws {
        func fail(_ message: String) -> NSError {
            NSError(domain: "BlueDuck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        if config.displayName.trimmingCharacters(in: .whitespaces).isEmpty { throw fail("Enter a name.") }
        if config.bucket.trimmingCharacters(in: .whitespaces).isEmpty { throw fail("Enter a bucket name.") }
        if config.accessKeyID.isEmpty || secret.isEmpty { throw fail("Enter an access key ID and secret access key.") }
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespaces)
        if !endpoint.isEmpty {
            guard let url = URL(string: endpoint), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
                throw fail("The endpoint must be a URL such as https://s3.example.com.")
            }
        }
    }

    private func removeState(for id: String) {
        try? FileManager.default.removeItem(at: AppGroup.containerURL.appendingPathComponent("Domains/\(id)", isDirectory: true))
    }

    private static func domain(for config: DomainConfig) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(config.id), displayName: config.displayName)
    }

    private static func locationChanged(_ a: DomainConfig, _ b: DomainConfig) -> Bool {
        a.bucket != b.bucket || a.endpoint != b.endpoint || a.normalizedRootPrefix != b.normalizedRootPrefix
            || a.region != b.region || a.pathStyle != b.pathStyle
    }
}
