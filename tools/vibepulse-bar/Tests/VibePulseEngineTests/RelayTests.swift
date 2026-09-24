import XCTest
@testable import VibePulseRelay

final class RelayTests: XCTestCase {
    func testCanonicalJSONMatchesPythonEscapes() throws {
        let value = CanonicalJSON.Value.object([
            "b": .string("a\"b\\c"),
            "a": .string("line\n\r\t\u{08}\u{0C}"),
            "z": .string("snowman \u{2603} emoji \u{1F600} del \u{7F}"),
            "n": .int(1),
            "slash": .string("a/b"),
        ])
        let encoded = try CanonicalJSON.encode(value)
        let expected = #"{"a":"line\n\r\t\b\f","b":"a\"b\\c","n":1,"slash":"a/b","z":"snowman \u2603 emoji \ud83d\ude00 del \u007f"}"#
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), expected)
        guard case let .success(.object(parsed)) = CanonicalJSON.parse(encoded) else {
            return XCTFail("canonical object did not parse")
        }
        XCTAssertEqual(try CanonicalJSON.encode(.object(parsed)), encoded)
    }

    func testRequestEnvelopeMatchesKnownCiphertext() throws {
        let vector = try loadVector()
        let inputs = vector["inputs"] as? [String: Any]
        let expected = vector["expected"] as? [String: Any]
        let deviceKey = try InteractionRelayCrypto.decodeDeviceKey(inputs?["deviceKeyHex"] as? String ?? "")
        let keys = try InteractionRelayCrypto.deriveKeys(
            deviceKey: deviceKey,
            mailbox: inputs?["mailbox"] as? String ?? ""
        )
        let envelope = try InteractionRelayCrypto.encodeRequest(
            keys: keys,
            mailbox: inputs?["mailbox"] as? String ?? "",
            requestID: inputs?["requestId"] as? String ?? "",
            challenge: hex(inputs?["challengeHex"] as? String ?? ""),
            expiresAt: UInt32((inputs?["expiresAt"] as? NSNumber)?.uint32Value ?? 0),
            viewBytes: Data((inputs?["viewUtf8"] as? String ?? "").utf8),
            nonce: hex(inputs?["requestNonceHex"] as? String ?? ""),
            padding: { Data(repeating: 0xA5, count: $0) }
        )
        let expectedEnvelope = expected?["requestEnvelopeUtf8"] as? String ?? ""
        XCTAssertEqual(envelope, Data(expectedEnvelope.utf8))
        let decoded = try InteractionRelayCrypto.decodeRequest(
            keys: keys,
            mailbox: inputs?["mailbox"] as? String ?? "",
            requestID: inputs?["requestId"] as? String ?? "",
            envelope: envelope
        )
        XCTAssertEqual(decoded.viewBytes, Data((inputs?["viewUtf8"] as? String ?? "").utf8))
        XCTAssertEqual(decoded.expiresAt, UInt32((inputs?["expiresAt"] as? NSNumber)?.uint32Value ?? 0))
        XCTAssertEqual(
            InteractionRelayCrypto.b64URLEncode(decoded.viewSHA256),
            expected?["viewSha256Base64url"] as? String
        )
    }

    func testRequestRoundTripAndOpaqueFailure() throws {
        let key = Data(repeating: 0x11, count: 32)
        let keys = try InteractionRelayCrypto.deriveKeys(deviceKey: key, mailbox: "vp_A1b2C3d4E5f6G7h8")
        let view = Data("round-trip".utf8)
        let challenge = Data(repeating: 0x22, count: 32)
        let envelope = try InteractionRelayCrypto.encodeRequest(
            keys: keys,
            mailbox: "vp_A1b2C3d4E5f6G7h8",
            requestID: "ABEiM0RVZneImaq7zN3u_w",
            challenge: challenge,
            expiresAt: 1_700_000_000,
            viewBytes: view
        )
        let decoded = try InteractionRelayCrypto.decodeRequest(
            keys: keys,
            mailbox: "vp_A1b2C3d4E5f6G7h8",
            requestID: "ABEiM0RVZneImaq7zN3u_w",
            envelope: envelope
        )
        XCTAssertEqual(decoded.viewBytes, view)
        XCTAssertEqual(decoded.challenge, challenge)
        var tampered = envelope
        tampered[tampered.index(tampered.startIndex, offsetBy: 20)] ^= 1
        XCTAssertThrowsError(try InteractionRelayCrypto.decodeRequest(
            keys: keys,
            mailbox: "vp_A1b2C3d4E5f6G7h8",
            requestID: "ABEiM0RVZneImaq7zN3u_w",
            envelope: tampered
        )) { error in
            XCTAssertEqual(error as? RelayCryptoError, .invalidRequestEnvelope)
        }
    }

    func testBase64URLRejectsPinnedInputs() {
        for sample in ["AA==", "AA=", "A", "+A", "/A", "AA\n", "å", "AB"] {
            XCTAssertThrowsError(try InteractionRelayCrypto.b64URLDecode(sample))
        }
        XCTAssertEqual(try InteractionRelayCrypto.b64URLDecode(""), Data())
    }

    private func loadVector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test-vectors/interaction-relay-v1.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private func hex(_ text: String) -> Data {
        var out = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            if let byte = UInt8(text[index..<next], radix: 16) { out.append(byte) }
            index = next
        }
        return out
    }
}
