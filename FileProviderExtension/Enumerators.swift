import BlueDuckKit
import FileProvider

private let batchSize = 200

/// Lists one folder. Changes are reported through the working set, so this enumerator never has any.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let ext: FileProviderExtension
    private let folderID: String

    init(ext: FileProviderExtension, folderID: String) {
        self.ext = ext
        self.folderID = folderID
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                report(try await ext.listFolder(folderID).children, to: observer)
            } catch where S3Client.isOffline(error) && ext.store.isListed(folderID) {
                // Offline: serve the last known listing.
                report(ext.store.children(of: folderID), to: observer)
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.mapError(error))
            }
        }
    }

    private func report(_ records: [ItemStore.Record], to observer: NSFileProviderEnumerationObserver) {
        for start in stride(from: 0, to: records.count, by: batchSize) {
            observer.didEnumerate(records[start..<min(start + batchSize, records.count)].map(ext.item))
        }
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: ext.currentAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(ext.currentAnchor)
    }
}

/// Reports remote changes by re-listing every folder the system has seen and diffing against the store.
///
/// S3 has no change feed, so this runs whenever the working set is signalled (the app does so
/// periodically and after local actions such as Keep Offline).
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let ext: FileProviderExtension

    init(ext: FileProviderExtension) {
        self.ext = ext
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let records = ext.store.allRecords.filter { $0.id != ItemStore.rootID }
        for start in stride(from: 0, to: records.count, by: batchSize) {
            observer.didEnumerate(records[start..<min(start + batchSize, records.count)].map(ext.item))
        }
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard ext.isCurrentGeneration(anchor) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        Task {
            var changedIDs = Set<String>()
            for folderID in ext.store.listedFolderIDs where ext.store.record(folderID) != nil {
                do {
                    // Deletions are queued in the store and collected by takePending below.
                    let result = try await ext.listFolder(folderID, signalDeletions: false)
                    changedIDs.formUnion(result.changed.map(\.id))
                } catch where S3Client.isOffline(error) {
                    break
                } catch {
                    continue
                }
            }

            let pending = ext.store.takePending()
            changedIDs.formUnion(pending.changed.map(\.id))
            let deleted = Set(pending.deleted)
            let updated = changedIDs.subtracting(deleted).compactMap { ext.store.record($0) }

            if !updated.isEmpty || !deleted.isEmpty { ext.store.bumpAnchor() }
            if !updated.isEmpty { observer.didUpdate(updated.map(ext.item)) }
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted.map { NSFileProviderItemIdentifier($0) }) }
            observer.finishEnumeratingChanges(upTo: ext.currentAnchor, moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(ext.currentAnchor)
    }
}

/// BlueDuck has no trash; S3 deletes are immediate.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    private let ext: FileProviderExtension

    init(ext: FileProviderExtension) {
        self.ext = ext
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: ext.currentAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(ext.currentAnchor)
    }
}
