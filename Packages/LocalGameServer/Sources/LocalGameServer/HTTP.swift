import Foundation

public struct HTTPRequest: Sendable, Hashable {
    public let method: String
    public let target: String
    public let version: String
    /// Header names lower-cased.
    public let headers: [String: String]

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: [String: String] = [:]) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
    }

    /// Percent-decoded path without the query string.
    public var path: String {
        let raw = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return raw.removingPercentEncoding ?? raw
    }

    public var keepAlive: Bool {
        if version == "HTTP/1.0" {
            return headers["connection"]?.lowercased() == "keep-alive"
        }
        return headers["connection"]?.lowercased() != "close"
    }
}

public enum HTTPBody: Sendable {
    case empty
    /// Small bodies only (≤ 1 MiB).
    case data(Data)
    /// Streamed in chunks; `range` is the inclusive byte window served (nil = whole file).
    case file(URL, range: ClosedRange<Int64>?, totalSize: Int64)
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: HTTPBody

    public init(status: Int, headers: [(String, String)] = [], body: HTTPBody = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: .data(Data(message.utf8)))
    }

    public var contentLength: Int64 {
        switch body {
        case .empty: 0
        case let .data(d): Int64(d.count)
        case let .file(_, range, total): range.map { $0.upperBound - $0.lowerBound + 1 } ?? total
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }
}

public protocol Router: Sendable {
    func route(_ request: HTTPRequest) async -> HTTPResponse
}

public enum HTTPParseError: Error, Equatable, Sendable {
    case headersTooLarge
    case malformed(String)
    case incomplete
}

/// Incremental HTTP/1.1 request-head parser. Bodies are not accepted: GET and HEAD only.
public enum HTTPRequestParser {
    public static let headerCap = 8 << 10

    /// Returns the request and the number of bytes consumed, or `.incomplete` when more bytes are needed.
    public static func parse(_ buffer: Data) throws -> (HTTPRequest, Int) {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > headerCap {
                throw HTTPParseError.headersTooLarge
            }
            throw HTTPParseError.incomplete
        }
        let headBytes = buffer[buffer.startIndex ..< end.lowerBound]
        if headBytes.count > headerCap {
            throw HTTPParseError.headersTooLarge
        }
        guard let head = String(bytes: headBytes, encoding: .utf8) else { throw HTTPParseError.malformed("non-UTF-8 header") }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, !requestLine[1].isEmpty,
              requestLine[2].hasPrefix("HTTP/1.") else { throw HTTPParseError.malformed("request line") }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformed("header line") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else { throw HTTPParseError.malformed("header name") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if let length = headers["content-length"], Int(length) ?? 0 > 0 {
            throw HTTPParseError.malformed("request body not accepted")
        }
        if headers["transfer-encoding"] != nil {
            throw HTTPParseError.malformed("request body not accepted")
        }
        let request = HTTPRequest(
            method: String(requestLine[0]),
            target: String(requestLine[1]),
            version: String(requestLine[2]),
            headers: headers
        )
        return (request, end.upperBound - buffer.startIndex)
    }
}

/// `Range: bytes=a-b | a- | -n` for a resource of `size` bytes. Nil = no header; `.unsatisfiable` → 416.
public enum ByteRange {
    public enum Parsed: Equatable, Sendable { case satisfiable(ClosedRange<Int64>), unsatisfiable, ignore }

    public static func parse(_ header: String?, size: Int64) -> Parsed {
        guard let header, header.hasPrefix("bytes=") else { return .ignore }
        let spec = header.dropFirst(6)
        if spec.contains(",") {
            return .ignore
        } // multiple ranges: serve the whole file
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .unsatisfiable }
        let first = Int64(parts[0]), last = Int64(parts[1])
        guard size > 0 else { return .unsatisfiable }
        switch (first, last) {
        case let (a?, b?): return a <= b && a < size ? .satisfiable(a ... min(b, size - 1)) : .unsatisfiable
        case let (a?, nil): return a < size ? .satisfiable(a ... size - 1) : .unsatisfiable
        case let (nil, n?): return n > 0 ? .satisfiable(max(0, size - n) ... size - 1) : .unsatisfiable
        default: return .unsatisfiable
        }
    }
}
