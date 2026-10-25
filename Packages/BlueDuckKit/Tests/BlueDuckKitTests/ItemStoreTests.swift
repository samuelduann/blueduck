import BlueDuckKit
import XCTest

final class ItemStoreTests: XCTestCase {
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("itemstore-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func obj(_ key: String, etag: String = "e1", size: Int64 = 1) -> S3Object {
        S3Object(key: key, size: size, lastModified: Date(), etag: etag)
    }

    func testListingDiffDetectsAddsUpdatesAndDeletes() {
        let store = ItemStore(url: url, rootPrefix: "")
        var result = store.applyListing(folderID: ItemStore.rootID, objects: [obj("a.txt"), obj("b.txt")], subfolders: ["docs/"])
        XCTAssertEqual(result.changed.count, 3)
        let docsID = store.record(forKey: "docs/")!.id

        result = store.applyListing(folderID: ItemStore.rootID, objects: [obj("a.txt", etag: "e2")], subfolders: ["docs/"])
        XCTAssertEqual(result.changed.map(\.name), ["a.txt"])
        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertNil(store.record(forKey: "b.txt"))
        XCTAssertEqual(store.record(forKey: "docs/")?.id, docsID, "identifiers stay stable")
    }

    func testFolderMarkerAndNestedKeysAreSkipped() {
        let store = ItemStore(url: url, rootPrefix: "root/")
        store.applyListing(folderID: ItemStore.rootID, objects: [obj("root/"), obj("root/x.txt")], subfolders: ["root/sub/"])
        XCTAssertEqual(Set(store.children(of: ItemStore.rootID).map(\.name)), ["x.txt", "sub"])
    }

    func testFolderWinsOverSameNamedFile() {
        let store = ItemStore(url: url, rootPrefix: "")
        store.applyListing(folderID: ItemStore.rootID, objects: [obj("dup")], subfolders: ["dup/"])
        XCTAssertEqual(store.children(of: ItemStore.rootID).map(\.isFolder), [true])
    }

    func testMoveRekeysDescendantsAndKeepsIdentifiers() {
        let store = ItemStore(url: url, rootPrefix: "")
        store.applyListing(folderID: ItemStore.rootID, objects: [], subfolders: ["a/", "b/"])
        let a = store.record(forKey: "a/")!
        let b = store.record(forKey: "b/")!
        store.applyListing(folderID: a.id, objects: [obj("a/f.txt")], subfolders: ["a/deep/"])
        let deep = store.record(forKey: "a/deep/")!
        store.applyListing(folderID: deep.id, objects: [obj("a/deep/g.txt")], subfolders: [])
        let g = store.record(forKey: "a/deep/g.txt")!

        store.move(id: a.id, toParent: b.id, name: "renamed")
        XCTAssertEqual(store.record(a.id)?.key, "b/renamed/")
        XCTAssertEqual(store.record(g.id)?.key, "b/renamed/deep/g.txt")
        XCTAssertEqual(store.record(forKey: "b/renamed/deep/g.txt")?.id, g.id)
        XCTAssertNil(store.record(forKey: "a/deep/g.txt"))
    }

    func testPinsInheritAndPersist() {
        let store = ItemStore(url: url, rootPrefix: "")
        store.applyListing(folderID: ItemStore.rootID, objects: [], subfolders: ["photos/"])
        let photos = store.record(forKey: "photos/")!
        store.applyListing(folderID: photos.id, objects: [obj("photos/1.jpg")], subfolders: [])
        let pic = store.record(forKey: "photos/1.jpg")!

        XCTAssertFalse(store.isEffectivelyPinned(pic.id))
        let affected = store.setPin(.keep, for: photos.id)
        XCTAssertEqual(Set(affected), [photos.id, pic.id])
        XCTAssertTrue(store.isEffectivelyPinned(pic.id))

        store.setPin(.lazy, for: pic.id)
        XCTAssertFalse(store.isEffectivelyPinned(pic.id))
        XCTAssertTrue(store.isEffectivelyPinned(photos.id))

        let reloaded = ItemStore(url: url, rootPrefix: "")
        XCTAssertEqual(reloaded.record(photos.id)?.pin, .keep)
        XCTAssertEqual(Set(reloaded.takePending().changed.map(\.id)), [photos.id, pic.id])
        XCTAssertTrue(reloaded.takePending().changed.isEmpty)
    }

    func testInsertOverExistingKeyKeepsIdentifier() {
        let store = ItemStore(url: url, rootPrefix: "")
        store.applyListing(folderID: ItemStore.rootID, objects: [obj("a.txt")], subfolders: [])
        let original = store.record(forKey: "a.txt")!
        let replaced = store.insert(parentID: ItemStore.rootID, name: "a.txt", isFolder: false, size: 9, etag: "e9", mtime: Date())
        XCTAssertEqual(replaced?.id, original.id)
        XCTAssertEqual(store.record(original.id)?.etag, "e9")
    }

    func testChangingRootPrefixResetsGeneration() {
        let first = ItemStore(url: url, rootPrefix: "")
        let generation = first.generation
        XCTAssertEqual(ItemStore(url: url, rootPrefix: "").generation, generation)
        XCTAssertNotEqual(ItemStore(url: url, rootPrefix: "other/").generation, generation)
    }
}
