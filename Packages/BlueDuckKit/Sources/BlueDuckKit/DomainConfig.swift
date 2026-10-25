import Foundation
import Security

/// One mounted bucket. Each config backs one File Provider domain with the same identifier.
public struct DomainConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var bucket: String
    public var region: String
    /// Custom S3-compatible endpoint (e.g. `https://<account>.r2.cloudflarestorage.com`). Empty means AWS.
    public var endpoint: String
    public var pathStyle: Bool
    /// Optional folder inside the bucket to use as the root.
    public var rootPrefix: String
    public var accessKeyID: String

    public init(
        id: String = UUID().uuidString,
        displayName: String = "",
        bucket: String = "",
        region: String = "us-east-1",
        endpoint: String = "",
        pathStyle: Bool = false,
        rootPrefix: String = "",
        accessKeyID: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.bucket = bucket
        self.region = region
        self.endpoint = endpoint
        self.pathStyle = pathStyle
        self.rootPrefix = rootPrefix
        self.accessKeyID = accessKeyID
    }

    /// The root prefix normalized to "" or "folder/".
    public var normalizedRootPrefix: String {
        let trimmed = rootPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : trimmed + "/"
    }

    public var s3Endpoint: S3Client.Endpoint {
        let url = endpoint.trimmingCharacters(in: .whitespaces)
        return S3Client.Endpoint(
            bucket: bucket,
            region: region,
            endpoint: url.isEmpty ? nil : URL(string: url),
            pathStyle: pathStyle
        )
    }

    public func makeClient(secret: String) -> S3Client {
        S3Client(endpoint: s3Endpoint, credentials: S3Credentials(accessKeyID: accessKeyID, secretAccessKey: secret))
    }
}

/// Shared storage location for the app and the File Provider extension.
public enum AppGroup {
    /// Set per target in Info.plist as `$(TeamIdentifierPrefix)club.vaniti.blueduck`.
    public static var identifier: String {
        Bundle.main.object(forInfoDictionaryKey: "BlueDuckAppGroup") as? String ?? "club.vaniti.blueduck"
    }

    public static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        // Unsigned development builds have no app group container.
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlueDuck", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}

/// Reads and writes the list of configured buckets.
public enum ConfigStore {
    static var url: URL { AppGroup.containerURL.appendingPathComponent("domains.json") }

    public static func load() -> [DomainConfig] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DomainConfig].self, from: data)) ?? []
    }

    public static func save(_ configs: [DomainConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configs).write(to: url, options: .atomic)
    }

    public static func config(id: String) -> DomainConfig? {
        load().first { $0.id == id }
    }
}

/// Stores S3 secret keys in the data-protection keychain, shared through the app group.
public enum CredentialStore {
    static let service = "club.vaniti.blueduck.s3-secret"

    private static func query(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) != nil {
            q[kSecAttrAccessGroup as String] = AppGroup.identifier
        }
        return q
    }

    public static func secret(for configID: String) -> String? {
        var q = query(account: configID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func setSecret(_ secret: String, for configID: String) throws {
        let data = Data(secret.utf8)
        let q = query(account: configID)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    public static func deleteSecret(for configID: String) {
        SecItemDelete(query(account: configID) as CFDictionary)
    }

    private static func keychainError(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)",
        ])
    }
}
