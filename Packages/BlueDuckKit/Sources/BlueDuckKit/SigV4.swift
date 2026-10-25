import CryptoKit
import Foundation

public struct S3Credentials: Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

/// AWS Signature Version 4 request signing for S3.
enum SigV4 {
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    static let emptyPayloadHash = sha256Hex(Data())

    /// Characters that never need percent-encoding (RFC 3986 unreserved).
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    /// Encodes a query name/value or a single path segment.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Encodes an object key for use in a URL path, keeping `/` separators.
    static func encodePath(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }

    static func canonicalQuery(_ items: [(String, String)]) -> String {
        let encoded: [(name: String, value: String)] = items.map { (encode($0.0), encode($0.1)) }
        let sorted = encoded.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// Adds `x-amz-*` and `Authorization` headers to `request`.
    /// - Parameters:
    ///   - encodedPath: the already percent-encoded path exactly as it appears in the URL.
    ///   - canonicalQuery: the query string exactly as it appears in the URL.
    static func sign(
        _ request: inout URLRequest,
        hostHeader: String,
        encodedPath: String,
        canonicalQuery: String,
        payloadHash: String,
        credentials: S3Credentials,
        region: String,
        date: Date = Date()
    ) {
        let amzDate = timestamp(date, format: "yyyyMMdd'T'HHmmss'Z'")
        let dateStamp = String(amzDate.prefix(8))

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = credentials.sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        var headers: [String: String] = ["host": hostHeader]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name.lowercased().hasPrefix("x-amz-") {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let sortedNames = headers.keys.sorted()
        let canonicalHeaders = sortedNames.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = sortedNames.joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            encodedPath.isEmpty ? "/" : encodedPath,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [dateStamp, region, "s3", "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.string(from: date)
    }
}
