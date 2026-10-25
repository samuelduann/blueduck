import BlueDuckKit
import FileProvider
import os

let log = Logger(subsystem: "club.vaniti.blueduck.FileProvider", category: "extension")

enum ActionID {
    static let keepOffline = "club.vaniti.blueduck.action.keepOffline"
    static let removeOffline = "club.vaniti.blueduck.action.removeOffline"
}

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction {
    let domain: NSFileProviderDomain
    let manager: NSFileProviderManager?
    let client: S3Client?
    let store: ItemStore

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        manager = NSFileProviderManager(for: domain)
        let config = ConfigStore.config(id: domain.identifier.rawValue)
        if let config, let secret = CredentialStore.secret(for: config.id) {
            client = config.makeClient(secret: secret)
        } else {
            log.error("No configuration or credentials for domain \(domain.identifier.rawValue, privacy: .public)")
            client = nil
        }
        let dir = AppGroup.containerURL.appendingPathComponent("Domains/\(domain.identifier.rawValue)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ItemStore(url: dir.appendingPathComponent("items.json"), rootPrefix: config?.normalizedRootPrefix ?? "")
        super.init()
    }

    func invalidate() {}

    // MARK: - Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let record = store.record(identifier.rawValue) {
            completionHandler(item(record), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        perform(progress, onError: { completionHandler(nil, nil, $0) }) { [self] in
            guard let record = store.record(itemIdentifier.rawValue), !record.isFolder else {
                throw NSFileProviderError(.noSuchItem)
            }
            let (url, updated) = try await downloadWhole(record, progress: progress)
            completionHandler(url, item(updated), nil)
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        perform(progress, onError: { completionHandler(nil, [], false, $0) }) { [self] in
            let name = itemTemplate.filename
            if Self.isExcluded(name) || itemTemplate.contentType == .symbolicLink {
                throw NSFileProviderError(.excludedFromSync)
            }
            let client = try requireClient()
            let parentID = itemTemplate.parentItemIdentifier.rawValue
            let isFolder = itemTemplate.contentType == .folder
            guard let key = store.childKey(parentID: parentID, name: name, isFolder: isFolder) else {
                throw NSFileProviderError(.noSuchItem)
            }

            if let existing = store.record(forKey: key) {
                if isFolder {
                    // Folders merge: re-creating one that exists is not an error.
                    completionHandler(item(existing), [], false, nil)
                    return
                }
                if !options.contains(.mayAlreadyExist) {
                    throw NSFileProviderError(.filenameCollision)
                }
            }

            let record: ItemStore.Record?
            if isFolder {
                let etag = try await client.put(key: key, data: Data())
                record = store.insert(parentID: parentID, name: name, isFolder: true, size: 0, etag: etag, mtime: Date())
            } else {
                let etag: String
                var size: Int64 = 0
                if let url {
                    etag = try await client.put(key: key, file: url, progress: progress)
                    size = Self.fileSize(url)
                } else {
                    etag = try await client.put(key: key, data: Data())
                }
                record = store.insert(parentID: parentID, name: name, isFolder: false, size: size, etag: etag, mtime: Date())
            }
            guard let record else { throw NSFileProviderError(.noSuchItem) }
            completionHandler(item(record), [], false, nil)
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        perform(progress, onError: { completionHandler(nil, [], false, $0) }) { [self] in
            let client = try requireClient()
            guard var record = store.record(item.itemIdentifier.rawValue) else {
                throw NSFileProviderError(.noSuchItem)
            }
            if record.id == ItemStore.rootID {
                // The root maps to the bucket prefix itself; it cannot be renamed, moved or written.
                completionHandler(self.item(record), [], false, nil)
                return
            }
            // Folders cannot be moved, and only empty ones can be renamed (S3 would need every key under the prefix
            // copied); returning the stored path makes the system revert the change.
            var newName = changedFields.contains(.filename) ? item.filename : record.name
            if record.isFolder, newName != record.name {
                let page = try await client.listPage(prefix: record.key, delimiter: nil, maxKeys: 2)
                if page.objects.contains(where: { $0.key != record.key }) { newName = record.name }
            }
            let newParent = changedFields.contains(.parentItemIdentifier) && !record.isFolder
                ? item.parentItemIdentifier.rawValue : record.parentID
            let uploadContents = changedFields.contains(.contents) && !record.isFolder ? newContents : nil
            var uploaded = false

            if newName != record.name || newParent != record.parentID {
                guard let newKey = store.childKey(parentID: newParent, name: newName, isFolder: record.isFolder) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                if record.isFolder {
                    // An empty folder is just its marker object.
                    _ = try await client.put(key: newKey, data: Data())
                    try await client.delete(key: record.key)
                } else if let uploadContents {
                    let etag = try await client.put(key: newKey, file: uploadContents, progress: progress)
                    try await client.delete(key: record.key)
                    record.etag = etag
                    uploaded = true
                } else {
                    try await client.copy(from: record.key, to: newKey)
                    try await client.delete(key: record.key)
                }
                guard let moved = store.move(id: record.id, toParent: newParent, name: newName) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                record = moved
                if uploaded, let uploadContents {
                    record = store.updateContent(id: record.id, size: Self.fileSize(uploadContents), etag: record.etag, mtime: Date()) ?? record
                }
            }

            if let uploadContents, !uploaded {
                let etag = try await client.put(key: record.key, file: uploadContents, progress: progress)
                record = store.updateContent(id: record.id, size: Self.fileSize(uploadContents), etag: etag, mtime: Date()) ?? record
            }
            // Other metadata (dates, tags, xattrs) has no S3 equivalent and is accepted as-is.
            completionHandler(self.item(record), [], false, nil)
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        perform(progress, onError: completionHandler) { [self] in
            let client = try requireClient()
            guard let record = store.record(identifier.rawValue) else {
                completionHandler(nil)  // Already gone.
                return
            }
            if record.isFolder {
                let all = try await client.listAll(prefix: record.key, delimiter: nil)
                if !options.contains(.recursive), all.objects.contains(where: { $0.key != record.key }) {
                    throw NSFileProviderError(.directoryNotEmpty)
                }
                try await client.delete(keys: Array(Set(all.objects.map(\.key) + [record.key])))
            } else {
                try await client.delete(key: record.key)
            }
            store.remove(id: record.id)
            completionHandler(nil)
        }
        return progress
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .workingSet:
            return WorkingSetEnumerator(ext: self)
        case .trashContainer:
            return EmptyEnumerator(ext: self)
        default:
            guard let record = store.record(containerItemIdentifier.rawValue), record.isFolder else {
                throw NSFileProviderError(.noSuchItem)
            }
            return FolderEnumerator(ext: self, folderID: record.id)
        }
    }

    /// Lists a folder on S3 and updates the store. Deletions are queued for the working set.
    /// - Returns: the folder's children and the records added or changed since the last listing.
    @discardableResult
    func listFolder(_ folderID: String, signalDeletions: Bool = true) async throws -> (children: [ItemStore.Record], changed: [ItemStore.Record]) {
        let client = try requireClient()
        guard let folder = store.record(folderID) else { throw NSFileProviderError(.noSuchItem) }
        let listing = try await client.listAll(prefix: folder.key, delimiter: "/")
        let result = store.applyListing(folderID: folderID, objects: listing.objects, subfolders: listing.prefixes)
        if !result.deleted.isEmpty {
            store.markDeleted(result.deleted)
            if signalDeletions { signalWorkingSet() }
        }
        return (store.children(of: folderID), result.changed)
    }

    var currentAnchor: NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(store.generation):\(store.anchor)".utf8))
    }

    func isCurrentGeneration(_ anchor: NSFileProviderSyncAnchor) -> Bool {
        String(decoding: anchor.rawValue, as: UTF8.self).hasPrefix(store.generation + ":")
    }

    func signalWorkingSet() {
        manager?.signalEnumerator(for: .workingSet) { error in
            if let error { log.error("signalEnumerator failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Finder actions

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        perform(progress, onError: completionHandler) { [self] in
            let ids = itemIdentifiers.map(\.rawValue)
            switch actionIdentifier.rawValue {
            case ActionID.keepOffline:
                for id in ids {
                    // Make the whole subtree known first so every file gets the eager policy.
                    if store.record(id)?.isFolder == true { try await discoverSubtree(id) }
                    store.setPin(.keep, for: id)
                    progress.completedUnitCount += 1
                }
                signalWorkingSet()
                completionHandler(nil)

            case ActionID.removeOffline:
                for id in ids {
                    guard let record = store.record(id) else { continue }
                    // Inside a kept-offline folder an explicit opt-out is needed; elsewhere inherit.
                    store.setPin(store.isEffectivelyPinned(record.parentID) ? .lazy : nil, for: id)
                    progress.completedUnitCount += 1
                }
                signalWorkingSet()
                completionHandler(nil)
                await evict(itemIdentifiers)

            default:
                throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            }
        }
        return progress
    }

    /// Lists every folder beneath `folderID` so all descendants exist in the store.
    private func discoverSubtree(_ folderID: String) async throws {
        var queue = [folderID]
        while let next = queue.popLast() {
            let children = try await listFolder(next).children
            queue += children.filter(\.isFolder).map(\.id)
            store.markChanged(children.map(\.id))
        }
    }

    /// Evicts local copies once the system has picked up the new content policy.
    private func evict(_ identifiers: [NSFileProviderItemIdentifier]) async {
        guard let manager else { return }
        for identifier in identifiers {
            for attempt in 0..<5 {
                try? await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
                do {
                    try await manager.evictItem(identifier: identifier)
                    break
                } catch {
                    log.info("Evict attempt \(attempt) for \(identifier.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Helpers

    func item(_ record: ItemStore.Record) -> FileProviderItem {
        FileProviderItem(record: record, pinned: store.isEffectivelyPinned(record.id))
    }

    /// A new file in the system's temporary directory, which is on the same volume as the domain.
    func temporaryFileURL() -> URL {
        let dir = (try? manager?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(UUID().uuidString)
    }

    /// Downloads the current version of a file and records its ETag and size if they changed.
    func downloadWhole(_ record: ItemStore.Record, progress: Progress) async throws -> (URL, ItemStore.Record) {
        let client = try requireClient()
        let destination = temporaryFileURL()
        let etag = try await client.download(key: record.key, to: destination, progress: progress)
        let size = Self.fileSize(destination)
        var record = record
        if etag != record.etag || size != record.size {
            record = store.updateContent(id: record.id, size: size, etag: etag, mtime: Date()) ?? record
        }
        return (destination, record)
    }

    func requireClient() throws -> S3Client {
        guard let client else { throw NSFileProviderError(.notAuthenticated) }
        return client
    }

    /// Runs async work for a File Provider callback, mapping errors and wiring cancellation.
    func perform(_ progress: Progress, onError: @escaping (Error) -> Void, _ work: @escaping () async throws -> Void) {
        let task = Task {
            do {
                try await work()
            } catch {
                log.error("Operation failed: \(String(describing: error), privacy: .public)")
                onError(Self.mapError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
    }

    static func mapError(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        }
        if error is NSFileProviderError { return error }
        if S3Client.isOffline(error) { return NSFileProviderError(.serverUnreachable) }
        if let s3 = error as? S3Error {
            switch (s3.status, s3.code) {
            case (404, _):
                return NSFileProviderError(.noSuchItem)
            case (_, "InvalidAccessKeyId"), (_, "SignatureDoesNotMatch"), (_, "ExpiredToken"), (_, "InvalidToken"):
                return NSFileProviderError(.notAuthenticated)
            case (403, _):
                return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                               userInfo: [NSLocalizedDescriptionKey: s3.description])
            default:
                return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                               userInfo: [NSLocalizedDescriptionKey: s3.description])
            }
        }
        return error
    }

    /// Finder metadata files that should never be uploaded to the bucket.
    static func isExcluded(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == ".localized"
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
