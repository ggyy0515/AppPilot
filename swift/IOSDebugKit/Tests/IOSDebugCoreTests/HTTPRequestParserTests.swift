import Foundation
import Testing
@testable import IOSDebugCore

@Test func parsesFragmentedRequest() throws {
    var parser = HTTPRequestParser()
    let wire = Data("POST /v1/actions/activate HTTP/1.1\r\nHost: localhost\r\nContent-Length: 32\r\n\r\n{\"identifier\":\"header.settings\"}".utf8)
    var request: HTTPRequest?
    for byte in wire { request = try parser.append(Data([byte])) ?? request }
    #expect(request?.method == .post)
    #expect(request?.path == "/v1/actions/activate")
    #expect(request?.headers["host"] == "localhost")
    #expect(request?.body == Data("{\"identifier\":\"header.settings\"}".utf8))
}

@Test func acceptsASCIIHeaderNameContainingSpace() throws {
    var parser = HTTPRequestParser()
    let wire = Data("GET /v1/health HTTP/1.1\r\nX Debug: enabled\r\n\r\n".utf8)
    let parsed = try parser.append(wire)
    let request = try #require(parsed)
    #expect(request.headers["x debug"] == "enabled")
}

@Test(arguments: ["PUT", "PATCH", "CONNECT", "OPTIONS", "TRACE"])
func rejectsUnsupportedMethods(_ method: String) {
    expectError(.unsupportedMethod, wire: "\(method) /v1/health HTTP/1.1\r\nHost: localhost\r\n\r\n")
}

@Test func enforcesHeaderByteLimit() throws {
    let fixed = "GET /v1/health HTTP/1.1\r\nX-Padding: \r\n\r\n"
    let acceptedWire = "GET /v1/health HTTP/1.1\r\nX-Padding: \(String(repeating: "a", count: IOSDebugProtocol.maximumHeaderBytes - fixed.utf8.count))\r\n\r\n"
    #expect(acceptedWire.utf8.count == IOSDebugProtocol.maximumHeaderBytes)
    var accepted = HTTPRequestParser()
    #expect(try accepted.append(Data(acceptedWire.utf8))?.path == "/v1/health")

    let rejectedWire = "GET /v1/health HTTP/1.1\r\nX-Padding: \(String(repeating: "a", count: IOSDebugProtocol.maximumHeaderBytes - fixed.utf8.count + 1))\r\n\r\n"
    var rejected = HTTPRequestParser()
    #expect(throws: HTTPParseError.headerTooLarge) {
        try rejected.append(Data(rejectedWire.utf8))
    }
}

@Test func enforcesBodyByteLimit() throws {
    let limit = IOSDebugProtocol.maximumRequestBodyBytes
    var accepted = HTTPRequestParser()
    let acceptedWire = Data("POST /v1/upload HTTP/1.1\r\nContent-Length: \(limit)\r\n\r\n".utf8) + Data(repeating: 0x61, count: limit)
    #expect(try accepted.append(acceptedWire)?.body.count == limit)

    expectError(.bodyTooLarge, wire: "POST /v1/upload HTTP/1.1\r\nContent-Length: \(limit + 1)\r\n\r\n")
}

@Test(arguments: [
    "POST /v1/action HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na",
    "POST /v1/action HTTP/1.1\r\nContent-Length: nope\r\n\r\n",
    "POST /v1/action HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
    "POST /v1/action HTTP/1.1\r\n\r\n",
    "GET /v1/health HTTP/1.1\r\nContent-Length: 1\r\n\r\na",
    "HEAD /v1/health HTTP/1.1\r\nContent-Length: 1\r\n\r\na",
    "DELETE /v1/item HTTP/1.1\r\nContent-Length: 1\r\n\r\na",
])
func rejectsInvalidContentLengths(_ wire: String) {
    expectError(.malformedRequest, wire: wire)
}

@Test(arguments: ["chunked", "identity"])
func rejectsTransferEncoding(_ value: String) {
    expectError(.unsupportedTransferEncoding, wire: "POST /v1/action HTTP/1.1\r\nTransfer-Encoding: \(value)\r\n\r\n")
}

@Test(arguments: [
    "http://localhost/v1/health", "/v1/health?verbose=1", "/v1/health#part",
    "//v1/health", "/v1//health", "/v1/health/", "/",
])
func rejectsInvalidPaths(_ path: String) {
    expectError(.invalidPath, wire: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
}

@Test func rejectsInvalidUTF8() {
    var parser = HTTPRequestParser()
    var wire = Data("GET /v1/health HTTP/1.1\r\nX-Bad: ".utf8)
    wire.append(0xff)
    wire.append(Data("\r\n\r\n".utf8))
    #expect(throws: HTTPParseError.malformedRequest) { try parser.append(wire) }
}

@Test(arguments: [
    "GET /v1/health HTTP/1.0\r\n\r\n",
    "GET /v1/health HTTP/1.1 extra\r\n\r\n",
    "GET /v1/health HTTP/1.1\r\n folded\r\n\r\n",
    "GET /v1/health HTTP/1.1\r\nMissingColon\r\n\r\n",
    "GET /v1/health HTTP/1.1\r\nX-Value: one:two\r\n\r\n",
    "GET /v1/health HTTP/1.1\r\n: value\r\n\r\n",
    "GET /v1/health HTTP/1.1\r\nBäd: value\r\n\r\n",
])
func rejectsMalformedRequests(_ wire: String) {
    expectError(.malformedRequest, wire: wire)
}

@Test func rejectsBytesAfterDeclaredBody() {
    expectError(.trailingBytes, wire: "POST /v1/action HTTP/1.1\r\nContent-Length: 1\r\n\r\nab")
}

private func expectError(_ error: HTTPParseError, wire: String) {
    var parser = HTTPRequestParser()
    #expect(throws: error) { try parser.append(Data(wire.utf8)) }
}
