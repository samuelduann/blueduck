import BlueDuckKit
import FileProvider
import UniformTypeIdentifiers

/// Exposes an `ItemStore.Record` to the File Provider system.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let record: ItemStore.Record
    /// Whether the item is kept offline directly or through a parent folder.
    let pinned: Bool

    init(record: ItemStore.Record, pinned: Bool) {
        self.record = record
        self.pinned = pinned
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(record.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(record.parentID)
    }

    var filename: String {
        // The root's key is empty, but the system rejects items without a filename.
        record.id == ItemStore.rootID ? "BlueDuck" : record.name
    }

    var contentType: UTType {
        if record.isFolder { return .folder }
        let ext = (record.name as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if record.id == ItemStore.rootID {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        }
        // No .allowsTrashing: S3 has no trash, so Finder deletes immediately.
        // No .allowsRenaming or .allowsReparenting on folders: directory paths are fixed.
        if record.isFolder {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting]
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
    }

    var documentSize: NSNumber? {
        record.isFolder ? nil : NSNumber(value: record.size)
    }

    var contentModificationDate: Date? { record.mtime }
    var creationDate: Date? { record.mtime }

    var itemVersion: NSFileProviderItemVersion {
        let content = Data((record.isFolder ? "folder" : record.etag).utf8)
        let metadata = Data("\(record.etag)|\(record.size)|\(record.mtime.timeIntervalSince1970)|\(record.pin?.rawValue ?? "-")|\(pinned)".utf8)
        return NSFileProviderItemVersion(contentVersion: content, metadataVersion: metadata)
    }

    var contentPolicy: NSFileProviderContentPolicy {
        switch record.pin {
        case .keep: return .downloadEagerlyAndKeepDownloaded
        case .lazy: return .downloadLazily
        case nil: return .inherited
        }
    }

    /// Read by the Finder action activation rules in Info.plist.
    var userInfo: [AnyHashable: Any]? {
        ["pinned": pinned]
    }
}
