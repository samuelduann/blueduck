import Foundation

/// Persistent mirror of what the File Provider system knows about a bucket.
///
/// File Provider identifiers must stay stable across renames, but S3 objects are addressed by key.
/// The store assigns each key a UUID identifier, re-keys records when items move, and keeps
/// the last listing of every folder so remote changes can be detected by diffing.
public final class ItemStore: @unchecked Sendable {
    public static let rootID = "NSFileProviderRootContainerItemIdentifier"

    /// Explicit offline preference. `nil` inherits from the parent folder.
    public enum Pin: String, Codable, Sendable {
        case keep
        case lazy
    }

    public struct Record: Codable, Equatable, Sendable {
        public var id: String
        /// Object key; folders end with "/". The root's key is the root prefix.
        public var key: String
        public var parentID: String
        public var isFolder: Bool
        public var size: Int64
        public var mtime: Date
        public var etag: String
        public var pin: Pin?

        public var name: String {
            var k = Substring(key)
            if k.hasSuffix("/") { k = k.dropLast() }
            return String(k.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        }
    }

    struct State: Codable {
        var generation = UUID().uuidString
        var rootPrefix = ""
        var anchor = 0
        var records: [String: Record] = [:]
        var listedFolders: Set<String> = []
        var pendingChanged: Set<String> = []
        var pendingDeleted: Set<String> = []
    }

    private let url: URL
    private let lock = NSRecursiveLock()
    private var state: State
    private var byKey: [String: String] = [:]
    private var children: [String: Set<String>] = [:]

    public init(url: URL, rootPrefix: String) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(State.self, from: data),
           loaded.rootPrefix == rootPrefix {
            state = loaded
        } else {
            state = State(rootPrefix: rootPrefix)
        }
        if state.records[Self.rootID] == nil {
            state.records[Self.rootID] = Record(
                id: Self.rootID, key: rootPrefix, parentID: Self.rootID, isFolder: true,
                size: 0, mtime: Date(), etag: "", pin: nil
            )
            // Persist immediately so the generation (and thus sync anchors) survive restarts.
            save()
        }
        rebuildIndexes()
    }

    // MARK: - Queries

    public var generation: String { lock.withLock { state.generation } }
    public var anchor: Int { lock.withLock { state.anchor } }
    public var listedFolderIDs: [String] { lock.withLock { Array(state.listedFolders) } }
    public var allRecords: [Record] { lock.withLock { Array(state.records.values) } }

    public func record(_ id: String) -> Record? {
        lock.withLock { state.records[id] }
    }

    public func record(forKey key: String) -> Record? {
        lock.withLock { byKey[key].flatMap { state.records[$0] } }
    }

    public func children(of id: String) -> [Record] {
        lock.withLock { (children[id] ?? []).compactMap { state.records[$0] } }
    }

    public func isListed(_ id: String) -> Bool {
        lock.withLock { state.listedFolders.contains(id) }
    }

    /// The key a child named `name` would have inside `parent`.
    public func childKey(parentID: String, name: String, isFolder: Bool) -> String? {
        lock.withLock {
            guard let parent = state.records[parentID], parent.isFolder else { return nil }
            return parent.key + name + (isFolder ? "/" : "")
        }
    }

    /// Whether the item is kept offline, either directly or through an ancestor folder.
    public func isEffectivelyPinned(_ id: String) -> Bool {
        lock.withLock {
            var current = state.records[id]
            while let rec = current {
                if let pin = rec.pin { return pin == .keep }
                if rec.id == Self.rootID { return false }
                current = state.records[rec.parentID]
            }
            return false
        }
    }

    /// Identifiers of every known record beneath `id`.
    public func descendants(of id: String) -> [String] {
        lock.withLock {
            var result: [String] = []
            var queue = Array(children[id] ?? [])
            while let next = queue.popLast() {
                result.append(next)
                queue += children[next] ?? []
            }
            return result
        }
    }

    // MARK: - Remote listings

    /// Applies a complete listing of a folder and returns what changed since the previous listing.
    @discardableResult
    public func applyListing(folderID: String, objects: [S3Object], subfolders: [String]) -> (changed: [Record], deleted: [String]) {
        lock.withLock {
            guard let folder = state.records[folderID], folder.isFolder else { return ([], []) }
            let prefix = folder.key
            var seen = Set<String>()
            var changed: [Record] = []
            var folderNames = Set<String>()

            for sub in subfolders where sub.hasPrefix(prefix) {
                let name = String(sub.dropFirst(prefix.count).dropLast())
                guard !name.isEmpty, !name.contains("/") else { continue }
                folderNames.insert(name)
                if let id = byKey[sub], state.records[id]?.isFolder == true {
                    seen.insert(id)
                } else {
                    let rec = insertLocked(Record(
                        id: UUID().uuidString, key: sub, parentID: folderID, isFolder: true,
                        size: 0, mtime: Date(), etag: "", pin: nil
                    ))
                    seen.insert(rec.id)
                    changed.append(rec)
                }
            }

            for obj in objects where obj.key != prefix && obj.key.hasPrefix(prefix) {
                let name = String(obj.key.dropFirst(prefix.count))
                // A folder and a file with the same name cannot coexist on disk; the folder wins.
                guard !name.isEmpty, !name.contains("/"), !folderNames.contains(name) else { continue }
                if let id = byKey[obj.key], var rec = state.records[id], !rec.isFolder {
                    seen.insert(id)
                    if rec.etag != obj.etag || rec.size != obj.size {
                        rec.etag = obj.etag
                        rec.size = obj.size
                        rec.mtime = obj.lastModified
                        state.records[id] = rec
                        changed.append(rec)
                    }
                } else {
                    let rec = insertLocked(Record(
                        id: UUID().uuidString, key: obj.key, parentID: folderID, isFolder: false,
                        size: obj.size, mtime: obj.lastModified, etag: obj.etag, pin: nil
                    ))
                    seen.insert(rec.id)
                    changed.append(rec)
                }
            }

            var deleted: [String] = []
            for id in children[folderID] ?? [] where !seen.contains(id) {
                deleted += removeLocked(id)
            }

            let firstListing = state.listedFolders.insert(folderID).inserted
            if firstListing || !changed.isEmpty || !deleted.isEmpty { save() }
            return (changed, deleted)
        }
    }

    // MARK: - Local changes

    /// Records an item created locally (already uploaded).
    @discardableResult
    public func insert(parentID: String, name: String, isFolder: Bool, size: Int64, etag: String, mtime: Date) -> Record? {
        lock.withLock {
            guard let parent = state.records[parentID], parent.isFolder else { return nil }
            let key = parent.key + name + (isFolder ? "/" : "")
            if let existingID = byKey[key], var existing = state.records[existingID] {
                // Re-imports and overwrites keep the identifier the system already knows.
                if existing.isFolder == isFolder {
                    existing.size = size
                    existing.etag = etag
                    existing.mtime = mtime
                    state.records[existingID] = existing
                    save()
                    return existing
                }
                _ = removeLocked(existingID)
            }
            let rec = insertLocked(Record(
                id: UUID().uuidString, key: key, parentID: parentID, isFolder: isFolder,
                size: size, mtime: mtime, etag: etag, pin: nil
            ))
            if isFolder { state.listedFolders.insert(rec.id) }
            save()
            return rec
        }
    }

    @discardableResult
    public func updateContent(id: String, size: Int64, etag: String, mtime: Date) -> Record? {
        lock.withLock {
            guard var rec = state.records[id] else { return nil }
            rec.size = size
            rec.etag = etag
            rec.mtime = mtime
            state.records[id] = rec
            save()
            return rec
        }
    }

    /// Moves/renames an item, re-keying it and everything beneath it.
    @discardableResult
    public func move(id: String, toParent newParentID: String, name: String) -> Record? {
        lock.withLock {
            guard var rec = state.records[id], let parent = state.records[newParentID] else { return nil }
            let oldKey = rec.key
            let newKey = parent.key + name + (rec.isFolder ? "/" : "")
            if let clash = byKey[newKey], clash != id { _ = removeLocked(clash) }

            children[rec.parentID]?.remove(id)
            children[newParentID, default: []].insert(id)
            rec.parentID = newParentID
            rec.key = newKey
            state.records[id] = rec
            byKey.removeValue(forKey: oldKey)
            byKey[newKey] = id

            if rec.isFolder {
                for child in descendants(of: id) {
                    guard var c = state.records[child] else { continue }
                    byKey.removeValue(forKey: c.key)
                    c.key = newKey + c.key.dropFirst(oldKey.count)
                    byKey[c.key] = child
                    state.records[child] = c
                }
            }
            save()
            return rec
        }
    }

    /// Removes an item and its descendants; returns every removed identifier.
    @discardableResult
    public func remove(id: String) -> [String] {
        lock.withLock {
            let removed = removeLocked(id)
            save()
            return removed
        }
    }

    /// Sets an explicit pin and clears explicit pins beneath it so the whole subtree follows.
    /// Returns the identifiers whose effective state may have changed.
    @discardableResult
    public func setPin(_ pin: Pin?, for id: String) -> [String] {
        lock.withLock {
            guard state.records[id] != nil else { return [] }
            state.records[id]?.pin = pin
            let below = descendants(of: id)
            for child in below { state.records[child]?.pin = nil }
            let affected = [id] + below
            state.pendingChanged.formUnion(affected)
            save()
            return affected
        }
    }

    // MARK: - Change tracking

    public func markChanged(_ ids: [String]) {
        lock.withLock {
            state.pendingChanged.formUnion(ids)
            save()
        }
    }

    public func markDeleted(_ ids: [String]) {
        lock.withLock {
            state.pendingDeleted.formUnion(ids)
            save()
        }
    }

    /// Returns and clears changes queued by local actions and listings.
    public func takePending() -> (changed: [Record], deleted: [String]) {
        lock.withLock {
            let changed = state.pendingChanged.compactMap { state.records[$0] }
            let deleted = Array(state.pendingDeleted)
            state.pendingChanged = []
            state.pendingDeleted = []
            save()
            return (changed, deleted)
        }
    }

    /// Advances and returns the sync anchor.
    @discardableResult
    public func bumpAnchor() -> Int {
        lock.withLock {
            state.anchor += 1
            save()
            return state.anchor
        }
    }

    // MARK: - Internals

    private func insertLocked(_ rec: Record) -> Record {
        state.records[rec.id] = rec
        byKey[rec.key] = rec.id
        children[rec.parentID, default: []].insert(rec.id)
        return rec
    }

    private func removeLocked(_ id: String) -> [String] {
        guard id != Self.rootID, let rec = state.records[id] else { return [] }
        let removed = [id] + descendants(of: id)
        for r in removed {
            if let gone = state.records.removeValue(forKey: r) { byKey.removeValue(forKey: gone.key) }
            children.removeValue(forKey: r)
            state.listedFolders.remove(r)
            state.pendingChanged.remove(r)
        }
        children[rec.parentID]?.remove(id)
        return removed
    }

    private func rebuildIndexes() {
        byKey = [:]
        children = [:]
        for (id, rec) in state.records {
            byKey[rec.key] = id
            if id != Self.rootID { children[rec.parentID, default: []].insert(id) }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
