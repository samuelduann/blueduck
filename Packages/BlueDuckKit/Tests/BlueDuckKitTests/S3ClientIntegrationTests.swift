import BlueDuckKit
import XCTest

/// Runs against a real S3-compatible server when BLUEDUCK_TEST_ENDPOINT is set, e.g.
/// BLUEDUCK_TEST_ENDPOINT=http://localhost:8333 BLUEDUCK_TEST_BUCKET=blueduck-test
/// BLUEDUCK_TEST_ACCESS_KEY=... BLUEDUCK_TEST_SECRET_KEY=... swift test
final class S3ClientIntegrationTests: XCTestCase {
    var client: S3Client!
    let prefix = "it-\(UUID().uuidString)/"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["BLUEDUCK_TEST_ENDPOINT"], let bucket = env["BLUEDUCK_TEST_BUCKET"],
              let access = env["BLUEDUCK_TEST_ACCESS_KEY"], let secret = env["BLUEDUCK_TEST_SECRET_KEY"] else {
            throw XCTSkip("BLUEDUCK_TEST_* not set")
        }
        client = S3Client(
            endpoint: .init(bucket: bucket, region: env["BLUEDUCK_TEST_REGION"] ?? "us-east-1", endpoint: URL(string: endpoint), pathStyle: true),
            credentials: S3Credentials(accessKeyID: access, secretAccessKey: secret)
        )
    }

    func testObjectLifecycle() async throws {
        let odd = prefix + "dir with space/naïve+name&(1).txt"
        let etag = try await client.put(key: odd, data: Data("hello world".utf8))
        XCTAssertFalse(etag.isEmpty)

        let head = try await client.head(key: odd)
        XCTAssertEqual(head?.size, 11)
        let missing = try await client.head(key: prefix + "missing")
        XCTAssertNil(missing)

        let range = try await client.getRange(key: odd, offset: 6, length: 5)
        XCTAssertEqual(String(decoding: range, as: UTF8.self), "world")

        let top = try await client.listAll(prefix: prefix, delimiter: "/")
        XCTAssertEqual(top.prefixes, [prefix + "dir with space/"])
        let inner = try await client.listAll(prefix: prefix + "dir with space/", delimiter: "/")
        XCTAssertEqual(inner.objects.map(\.key), [odd])
        XCTAssertEqual(inner.objects.first?.etag, etag)

        let copyKey = prefix + "copy.txt"
        try await client.copy(from: odd, to: copyKey)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) }
        let progress = Progress(totalUnitCount: 100)
        try await client.download(key: copyKey, to: dest, progress: progress)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "hello world")

        try await client.delete(keys: [odd, copyKey])
        let after = try await client.listAll(prefix: prefix, delimiter: nil)
        XCTAssertTrue(after.objects.isEmpty)
    }

    func testDownloadRangeIntoSparseFile() async throws {
        let key = prefix + "range.bin"
        let bytes = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let etag = try await client.put(key: key, data: bytes)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) }

        try await client.downloadRange(key: key, offset: 40_000, length: 10_000, into: dest, ifMatch: etag)
        try await client.downloadRange(key: key, offset: 90_000, length: 10_000, into: dest, ifMatch: etag)
        let written = try Data(contentsOf: dest)
        XCTAssertEqual(written.count, 100_000)
        XCTAssertEqual(written[40_000..<50_000], bytes[40_000..<50_000])
        XCTAssertEqual(written[90_000..<100_000], bytes[90_000..<100_000])

        // A stale ETag must be rejected instead of mixing versions.
        do {
            try await client.downloadRange(key: key, offset: 0, length: 10, into: dest, ifMatch: "0123456789abcdef0123456789abcdef")
            XCTFail("Expected 412 for a mismatched ETag")
        } catch let error as S3Error {
            XCTAssertEqual(error.status, 412)
        }
        try await client.delete(key: key)
    }

    func testMultipartUpload() async throws {
        let size = Int(S3Client.multipartThreshold) + 3 * 1024 * 1024
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: size, by: 4096) { raw[i] = UInt8(truncatingIfNeeded: i / 4096) }
        }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dest)
        }
        try bytes.write(to: src)

        let key = prefix + "big.bin"
        let progress = Progress(totalUnitCount: 100)
        try await client.put(key: key, file: src, progress: progress)
        XCTAssertEqual(progress.completedUnitCount, 100)
        try await client.download(key: key, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), bytes)
        try await client.delete(key: key)
    }
}
