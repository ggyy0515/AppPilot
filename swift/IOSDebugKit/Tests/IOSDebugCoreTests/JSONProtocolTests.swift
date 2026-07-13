import Foundation
import Testing
@testable import IOSDebugCore

@Test func encodableSnapshotBecomesJSONValue() throws {
    struct State: Encodable { let count: Int; let title: String }
    #expect(try JSONValue.encode(State(count: 2, title: "Home")) == .object([
        "count": .number(2), "title": .string("Home")
    ]))
}

@Test func successEnvelopeUsesStableKeys() throws {
    let data = try ProtocolJSON.success(data: .object(["ready": .bool(true)]), requestID: "req-1")
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(root == .object([
        "ok": .bool(true),
        "data": .object(["ready": .bool(true)]),
        "meta": .object(["protocol_version": .number(1), "request_id": .string("req-1")]),
    ]))
}

@Test func sha256MatchesKnownVector() {
    #expect(SHA256.hexDigest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}
