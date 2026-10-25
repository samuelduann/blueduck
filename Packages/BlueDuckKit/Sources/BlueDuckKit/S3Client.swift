import CryptoKit
import Foundation

public struct S3Object: Sendable, Hashable {
    public var key: String
    public var size: Int64
    public var lastModified: Date
    public var etag: String

    public init(key: String, size: Int64, lastModified: Date, etag: String) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.etag = etag
    }
}

public struct S3Error: Error, CustomStringConvertible {
    public var status: Int
    public var code: String
    public var message: String

    public var description: String {
        "S3 \(status) \(code)\(message.isEmpty ? "" : ": \(message)")"
    }
}

/// A minimal S3 REST client (ListObjectsV2, Head/Get/Put/Copy/Delete, multipart upload).
public final class S3Client: @unchecked Sendable {
    public struct Endpoint: Sendable {
        public var bucket: String
        public var region: String
        /// Custom endpoint such as `http://localhost:9000`. `nil` means AWS.
        public var endpoint: URL?
        public var pathStyle: Bool

        public init(bucket: String, region: String, endpoint: URL? = nil, pathStyle: Bool = false) {
            self.bucket = bucket
            self.region = region.isEmpty ? "us-east-1" : region
            self.endpoint = endpoint
            self.pathStyle = pathStyle
        }
    }

    public static let multipartThreshold: Int64 = 64 * 1024 * 1024
    static let minPartSize: Int64 = 16 * 1024 * 1024
    static let maxParts: Int64 = 10_000
    static let partConcurrency = 4

    public let endpoint: Endpoint
    private let credentials: S3Credentials
    private let session: URLSession
    private let scheme: String
    private let host: String
    private let port: Int?
    /// Path prefix that precedes the object key (`/bucket` for path-style addressing).
    private let basePath: String

    public init(endpoint: Endpoint, credentials: S3Credentials) {
        self.endpoint = endpoint
        self.credentials = credentials

        let base = endpoint.endpoint ?? URL(string: "https://s3.\(endpoint.region).amazonaws.com")!
        scheme = base.scheme ?? "https"
        port = base.port
        // Bucket names containing dots break TLS wildcard certificates with virtual-hosted style.
        let usePathStyle = endpoint.pathStyle || (scheme == "https" && endpoint.bucket.contains("."))
        let baseHost = base.host ?? "s3.amazonaws.com"
        if usePathStyle {
            host = baseHost
            basePath = "/" + SigV4.encode(endpoint.bucket)
        } else {
            host = "\(endpoint.bucket).\(baseHost)"
            basePath = ""
        }

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: config)
    }

    // MARK: - Listing

    public struct ListPage {
        public var objects: [S3Object] = []
        public var commonPrefixes: [String] = []
        public var nextToken: String?
    }

    public func listPage(prefix: String, delimiter: String?, continuationToken: String? = nil, maxKeys: Int = 1000) async throws -> ListPage {
        var query: [(String, String)] = [("list-type", "2"), ("prefix", prefix), ("max-keys", String(maxKeys))]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }

        let (data, _) = try await send("GET", key: nil, query: query)
        let root = try XMLTree.parse(data)
        var page = ListPage()
        for item in root.children("Contents") {
            guard let key = item.child("Key")?.text else { continue }
            page.objects.append(S3Object(
                key: key,
                size: Int64(item.child("Size")?.text ?? "") ?? 0,
                lastModified: Self.parseISODate(item.child("LastModified")?.text) ?? Date(),
                etag: Self.cleanETag(item.child("ETag")?.text)
            ))
        }
        for cp in root.children("CommonPrefixes") {
            if let p = cp.child("Prefix")?.text { page.commonPrefixes.append(p) }
        }
        if root.child("IsTruncated")?.text == "true" {
            page.nextToken = root.child("NextContinuationToken")?.text
        }
        return page
    }

    /// Lists every object and common prefix under `prefix`, following continuation tokens.
    public func listAll(prefix: String, delimiter: String?) async throws -> (objects: [S3Object], prefixes: [String]) {
        var objects: [S3Object] = []
        var prefixes: [String] = []
        var token: String?
        repeat {
            let page = try await listPage(prefix: prefix, delimiter: delimiter, continuationToken: token)
            objects += page.objects
            prefixes += page.commonPrefixes
            token = page.nextToken
        } while token != nil
        return (objects, prefixes)
    }

    // MARK: - Objects

    public func head(key: String) async throws -> S3Object? {
        do {
            let (_, response) = try await send("HEAD", key: key)
            return S3Object(
                key: key,
                size: Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
                lastModified: Self.parseHTTPDate(response.value(forHTTPHeaderField: "Last-Modified")) ?? Date(),
                etag: Self.cleanETag(response.value(forHTTPHeaderField: "ETag"))
            )
        } catch let error as S3Error where error.status == 404 {
            return nil
        }
    }

    /// Fetches `length` bytes starting at `offset`.
    public func getRange(key: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0 else { return Data() }
        let (data, _) = try await send("GET", key: key, headers: ["Range": "bytes=\(offset)-\(offset + length - 1)"])
        return data
    }

    /// Downloads the whole object to `destination` (replacing it) and returns its ETag.
    /// - Parameter progress: optional parent progress; the transfer is attached as a child.
    @discardableResult
    public func download(key: String, to destination: URL, progress: Progress? = nil) async throws -> String {
        let request = makeRequest("GET", key: key, payloadHash: SigV4.emptyPayloadHash)
        let (tmp, response) = try await session.download(for: request, delegate: progress.map(ProgressForwarder.init))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let http = response as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: (try? Data(contentsOf: tmp)) ?? Data(), response: http)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        return Self.cleanETag(http.value(forHTTPHeaderField: "ETag"))
    }

    /// Downloads `length` bytes starting at `offset` and writes them into `file` at the same offset,
    /// creating the file if needed. Bytes outside the range are left as they are (sparse in a new file).
    /// - Parameter ifMatch: when set, the request fails with status 412 if the object's ETag differs,
    ///   so ranges from different versions never end up in the same file.
    public func downloadRange(key: String, offset: Int64, length: Int64, into file: URL,
                              ifMatch: String? = nil, progress: Progress? = nil) async throws {
        guard length > 0 else { return }
        var headers = ["Range": "bytes=\(offset)-\(offset + length - 1)"]
        if let ifMatch, !ifMatch.isEmpty { headers["If-Match"] = "\"\(ifMatch)\"" }
        let request = makeRequest("GET", key: key, headers: headers, payloadHash: SigV4.emptyPayloadHash)
        let (tmp, response) = try await session.download(for: request, delegate: progress.map(ProgressForwarder.init))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let http = response as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: (try? Data(contentsOf: tmp)) ?? Data(), response: http)
        }
        // A server that ignores Range answers 200 with the whole object; skip to the requested bytes.
        let sourceOffset: UInt64 = http.statusCode == 206 ? 0 : UInt64(offset)

        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let source = try FileHandle(forReadingFrom: tmp)
        let destination = try FileHandle(forWritingTo: file)
        defer {
            try? source.close()
            try? destination.close()
        }
        try source.seek(toOffset: sourceOffset)
        try destination.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0, let chunk = try source.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty {
            try destination.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
        if remaining > 0 {
            throw S3Error(status: http.statusCode, code: "IncompleteBody",
                          message: "Expected \(length) bytes from \(key), got \(length - remaining).")
        }
    }

    @discardableResult
    public func put(key: String, data: Data) async throws -> String {
        let (_, response) = try await send("PUT", key: key, body: data)
        return Self.cleanETag(response.value(forHTTPHeaderField: "ETag"))
    }

    /// Uploads a local file, switching to multipart upload for large files.
    @discardableResult
    public func put(key: String, file: URL, progress: Progress? = nil) async throws -> String {
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 ?? 0
        if size >= Self.multipartThreshold {
            return try await multipartUpload(key: key, file: file, size: size, progress: progress)
        }
        var request = makeRequest("PUT", key: key, payloadHash: SigV4.unsignedPayload)
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.upload(
            for: request, fromFile: file, delegate: progress.map(ProgressForwarder.init))
        let http = try Self.check(response, data)
        return Self.cleanETag(http.value(forHTTPHeaderField: "ETag"))
    }

    public func delete(key: String) async throws {
        do {
            _ = try await send("DELETE", key: key)
        } catch let error as S3Error where error.status == 404 {
            // Already gone.
        }
    }

    /// Deletes many objects with DeleteObjects, 1000 keys per request.
    public func delete(keys: [String]) async throws {
        for start in stride(from: 0, to: keys.count, by: 1000) {
            let batch = keys[start..<min(start + 1000, keys.count)]
            var xml = "<Delete><Quiet>true</Quiet>"
            for key in batch { xml += "<Object><Key>\(Self.xmlEscape(key))</Key></Object>" }
            xml += "</Delete>"
            let body = Data(xml.utf8)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            let (data, _) = try await send("POST", key: nil, query: [("delete", "")], headers: ["Content-MD5": md5], body: body)
            if let failure = try? XMLTree.parse(data).child("Error") {
                throw Self.error(status: 500, root: failure)
            }
        }
    }

    /// Server-side copy (objects up to 5 GB). Returns the new ETag.
    @discardableResult
    public func copy(from source: String, to destination: String) async throws -> String {
        let copySource = "/\(SigV4.encode(endpoint.bucket))/\(SigV4.encodePath(source))"
        let (data, _) = try await send("PUT", key: destination, headers: ["x-amz-copy-source": copySource])
        // CopyObject can fail after returning 200; the error is then in the body.
        let root = try XMLTree.parse(data)
        if root.name == "Error" { throw Self.error(status: 500, root: root) }
        return Self.cleanETag(root.child("ETag")?.text)
    }

    // MARK: - Multipart

    private func multipartUpload(key: String, file: URL, size: Int64, progress: Progress?) async throws -> String {
        let (initData, _) = try await send("POST", key: key, query: [("uploads", "")])
        guard let uploadID = try XMLTree.parse(initData).child("UploadId")?.text else {
            throw S3Error(status: 500, code: "InvalidResponse", message: "Missing UploadId")
        }

        do {
            let partSize = max(Self.minPartSize, (size + Self.maxParts - 1) / Self.maxParts)
            let partCount = Int((size + partSize - 1) / partSize)
            var etags = [String](repeating: "", count: partCount)

            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var next = 0
                func addPart() {
                    let index = next
                    next += 1
                    group.addTask {
                        let offset = Int64(index) * partSize
                        let length = min(partSize, size - offset)
                        let handle = try FileHandle(forReadingFrom: file)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: UInt64(offset))
                        let body = try handle.read(upToCount: Int(length)) ?? Data()
                        let (_, response) = try await self.send(
                            "PUT", key: key,
                            query: [("partNumber", String(index + 1)), ("uploadId", uploadID)],
                            body: body
                        )
                        return (index, Self.cleanETag(response.value(forHTTPHeaderField: "ETag")))
                    }
                }
                for _ in 0..<min(Self.partConcurrency, partCount) { addPart() }
                var finished: Int64 = 0
                while let (index, etag) = try await group.next() {
                    etags[index] = etag
                    finished += 1
                    if let progress {
                        progress.completedUnitCount = progress.totalUnitCount * finished / Int64(partCount)
                    }
                    if next < partCount { addPart() }
                }
            }

            var xml = "<CompleteMultipartUpload>"
            for (i, etag) in etags.enumerated() {
                xml += "<Part><PartNumber>\(i + 1)</PartNumber><ETag>\"\(etag)\"</ETag></Part>"
            }
            xml += "</CompleteMultipartUpload>"
            let (data, _) = try await send("POST", key: key, query: [("uploadId", uploadID)], body: Data(xml.utf8))
            let root = try XMLTree.parse(data)
            if root.name == "Error" { throw Self.error(status: 500, root: root) }
            return Self.cleanETag(root.child("ETag")?.text)
        } catch {
            _ = try? await send("DELETE", key: key, query: [("uploadId", uploadID)])
            throw error
        }
    }

    // MARK: - Transport

    private func makeRequest(
        _ method: String,
        key: String?,
        query: [(String, String)] = [],
        headers: [String: String] = [:],
        payloadHash: String
    ) -> URLRequest {
        let encodedPath = basePath + "/" + (key.map(SigV4.encodePath) ?? "")
        let canonicalQuery = SigV4.canonicalQuery(query)
        var hostHeader = host
        if let port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            hostHeader += ":\(port)"
        }
        let urlString = "\(scheme)://\(hostHeader)\(encodedPath)" + (canonicalQuery.isEmpty ? "" : "?\(canonicalQuery)")
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        SigV4.sign(
            &request,
            hostHeader: hostHeader,
            encodedPath: encodedPath,
            canonicalQuery: canonicalQuery,
            payloadHash: payloadHash,
            credentials: credentials,
            region: endpoint.region
        )
        return request
    }

    @discardableResult
    private func send(
        _ method: String,
        key: String?,
        query: [(String, String)] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let payloadHash = body == nil ? SigV4.emptyPayloadHash : SigV4.unsignedPayload
        var request = makeRequest(method, key: key, query: query, headers: headers, payloadHash: payloadHash)
        let data: Data
        let response: URLResponse
        if let body {
            (data, response) = try await session.upload(for: request, from: body)
        } else {
            request.httpBody = nil
            (data, response) = try await session.data(for: request)
        }
        return (data, try Self.check(response, data))
    }

    private static func check(_ response: URLResponse, _ data: Data) throws -> HTTPURLResponse {
        let http = response as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw error(status: http.statusCode, body: data, response: http)
        }
        return http
    }

    private static func error(status: Int, body: Data, response: HTTPURLResponse) -> S3Error {
        var err = S3Error(status: status, code: HTTPURLResponse.localizedString(forStatusCode: status), message: "")
        if let root = try? XMLTree.parse(body) {
            err = error(status: status, root: root)
        }
        if let region = response.value(forHTTPHeaderField: "x-amz-bucket-region") {
            err.message += (err.message.isEmpty ? "" : " ") + "(bucket region is \(region))"
        }
        return err
    }

    private static func error(status: Int, root: XMLTree.Node) -> S3Error {
        S3Error(status: status, code: root.child("Code")?.text ?? "Unknown", message: root.child("Message")?.text ?? "")
    }

    // MARK: - Parsing helpers

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func cleanETag(_ etag: String?) -> String {
        (etag ?? "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "&quot;", with: "")
    }

    static func parseISODate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
    }

    static func parseHTTPDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}

extension S3Client {
    /// True for transport errors that indicate the endpoint is unreachable (as opposed to an S3 error).
    public static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .timedOut, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }
}

/// Attaches a URLSession task's progress to a caller-supplied parent progress.
private final class ProgressForwarder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let parent: Progress

    init(_ parent: Progress) { self.parent = parent }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        parent.addChild(task.progress, withPendingUnitCount: max(parent.totalUnitCount - parent.completedUnitCount, 0))
    }
}
