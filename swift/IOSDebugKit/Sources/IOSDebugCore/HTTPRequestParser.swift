import Foundation

public enum HTTPMethod: String, Sendable, Codable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case delete = "DELETE"
}

public struct HTTPRequest: Sendable, Equatable {
    public let method: HTTPMethod
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

public enum HTTPParseError: Error, Equatable {
    case headerTooLarge
    case bodyTooLarge
    case malformedRequest
    case unsupportedMethod
    case unsupportedTransferEncoding
    case invalidPath
    case trailingBytes
}

public struct HTTPRequestParser: Sendable {
    private static let delimiter = Data("\r\n\r\n".utf8)

    private var buffer = Data()
    private var parsedHead: (HTTPMethod, String, [String: String], Int)?
    public let maximumHeaderBytes: Int
    public let maximumBodyBytes: Int

    public init(
        maximumHeaderBytes: Int = IOSDebugProtocol.maximumHeaderBytes,
        maximumBodyBytes: Int = IOSDebugProtocol.maximumRequestBodyBytes
    ) {
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
    }

    public mutating func append(_ bytes: Data) throws -> HTTPRequest? {
        buffer.append(bytes)
        if parsedHead == nil {
            try parseHeadIfComplete()
        }

        guard let (method, path, headers, length) = parsedHead else { return nil }
        guard let delimiter = buffer.range(of: Self.delimiter) else {
            throw HTTPParseError.malformedRequest
        }
        let bodyStart = delimiter.upperBound
        guard buffer.count >= bodyStart + length else { return nil }
        guard buffer.count == bodyStart + length else { throw HTTPParseError.trailingBytes }

        return HTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: buffer.subdata(in: bodyStart..<buffer.count)
        )
    }

    private mutating func parseHeadIfComplete() throws {
        guard let delimiter = buffer.range(of: Self.delimiter) else {
            if buffer.count > maximumHeaderBytes { throw HTTPParseError.headerTooLarge }
            return
        }
        guard delimiter.upperBound <= maximumHeaderBytes else { throw HTTPParseError.headerTooLarge }

        let headerData = buffer.subdata(in: buffer.startIndex..<delimiter.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError.malformedRequest
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPParseError.malformedRequest }
        let tokens = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == 3, tokens[2] == "HTTP/1.1" else {
            throw HTTPParseError.malformedRequest
        }

        guard let method = HTTPMethod(rawValue: String(tokens[0])) else {
            throw HTTPParseError.unsupportedMethod
        }
        let path = String(tokens[1])
        guard isValidPath(path) else { throw HTTPParseError.invalidPath }

        var headers: [String: String] = [:]
        var hasContentLength = false
        for line in lines.dropFirst() {
            guard !line.isEmpty, line.first != " ", line.first != "\t" else {
                throw HTTPParseError.malformedRequest
            }
            guard line.filter({ $0 == ":" }).count == 1,
                let colon = line.firstIndex(of: ":")
            else {
                throw HTTPParseError.malformedRequest
            }
            let name = String(line[..<colon])
            guard isValidHeaderName(name) else { throw HTTPParseError.malformedRequest }
            let normalizedName = name.lowercased()
            if normalizedName == "content-length" {
                guard !hasContentLength else { throw HTTPParseError.malformedRequest }
                hasContentLength = true
            }
            let valueStart = line.index(after: colon)
            let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
            headers[normalizedName] = value
        }

        guard headers["transfer-encoding"] == nil else {
            throw HTTPParseError.unsupportedTransferEncoding
        }
        let length = try contentLength(in: headers, required: method == .post)
        guard length <= maximumBodyBytes else { throw HTTPParseError.bodyTooLarge }
        if method != .post, length != 0 { throw HTTPParseError.malformedRequest }
        parsedHead = (method, path, headers, length)
    }

    private func contentLength(in headers: [String: String], required: Bool) throws -> Int {
        guard let value = headers["content-length"] else {
            if required { throw HTTPParseError.malformedRequest }
            return 0
        }
        guard !value.isEmpty,
            value.allSatisfy({ $0.isASCII && $0.isNumber }),
            let length = Int(value)
        else { throw HTTPParseError.malformedRequest }
        return length
    }

    private func isValidPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path != "/",
            !path.hasSuffix("/"), !path.contains("?"), !path.contains("#")
        else { return false }
        return !path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains(where: \.isEmpty)
    }

    private func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { $0 < 0x80 }
    }
}
