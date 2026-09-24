import CryptoKit
import Foundation

public struct RelayCryptoError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public static let invalidRequestEnvelope = RelayCryptoError(message: "invalid request envelope")

    init(message: String) { self.message = message }
}

public struct RelayKeys: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let requestAEAD: Data
    public let verdictAEAD: Data
    public let verdictMAC: Data
    public let statusAEAD: Data

    public var description: String { "RelayKeys(redacted)" }
    public var debugDescription: String { "RelayKeys(redacted)" }
}

public struct RelayRequest: Sendable, Equatable {
    public let requestID: String
    public let challenge: Data
    public let expiresAt: UInt32
    public let viewBytes: Data
    public let viewSHA256: Data
}

public enum InteractionRelayCrypto {
    public static let requestFrameBytes = 2048
    public static let maxViewBytes = 640
    public static let maxEnvelopeBytes = 4096
    public static let gcmNonceBytes = 12
    public static let gcmTagBytes = 16

    private static let protocolPrefix = Data("vibepulse-ir/v1".utf8)
    private static let salt = Data(SHA256.hash(data: Data("VibePulse interaction relay v1".utf8)))
    private static let outerKeys: Set<String> = ["v", "nonce", "ciphertext"]
    private static let requestKeys: Set<String> = [
        "v", "requestId", "challenge", "expiresAt", "view", "viewSha256",
    ]

    public static func b64URLEncode(_ raw: Data) -> String {
        Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func b64URLDecode(_ text: String) throws -> Data {
        guard text.unicodeScalars.allSatisfy(isBase64URLScalar) else {
            throw RelayCryptoError(message: "invalid base64url")
        }
        if text.count % 4 == 1 {
            throw RelayCryptoError(message: "invalid base64url length")
        }
        let remainder = text.count % 4
        let padded = remainder == 0 ? text : text + String(repeating: "=", count: 4 - remainder)
        let standard = padded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let decoded = Data(base64Encoded: standard) else {
            throw RelayCryptoError(message: "invalid base64url")
        }
        guard b64URLEncode(decoded) == text else {
            throw RelayCryptoError(message: "non-canonical base64url")
        }
        return decoded
    }

    public static func decodeDeviceKey(_ hexText: String) throws -> Data {
        guard hexText.count == 64, hexText.unicodeScalars.allSatisfy(isHexScalar) else {
            throw RelayCryptoError(message: "device key must be exactly 64 hexadecimal characters")
        }
        var out = Data()
        out.reserveCapacity(32)
        var index = hexText.startIndex
        while index < hexText.endIndex {
            let next = hexText.index(index, offsetBy: 2)
            guard let byte = UInt8(hexText[index..<next], radix: 16) else {
                throw RelayCryptoError(message: "device key must be exactly 64 hexadecimal characters")
            }
            out.append(byte)
            index = next
        }
        return out
    }

    public static func deriveKeys(deviceKey: Data, mailbox: String) throws -> RelayKeys {
        guard deviceKey.count == 32 else {
            throw RelayCryptoError(message: "device key must be 32 bytes")
        }
        let mailboxBytes = try mailboxData(mailbox)
        func derive(_ label: String) throws -> Data {
            var info = protocolPrefix
            info.append(UInt8(ascii: "|"))
            info.append(mailboxBytes)
            info.append(UInt8(ascii: "|"))
            info.append(Data(label.utf8))
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: deviceKey),
                salt: salt,
                info: info,
                outputByteCount: 32
            )
            return key.withUnsafeBytes { Data($0) }
        }
        return RelayKeys(
            requestAEAD: try derive("mac-to-panel-aead"),
            verdictAEAD: try derive("panel-to-mac-aead"),
            verdictMAC: try derive("panel-verdict-mac"),
            statusAEAD: try derive("mac-to-panel-status-aead")
        )
    }

    public static func encodeRequest(
        keys: RelayKeys,
        mailbox: String,
        requestID: String,
        challenge: Data,
        expiresAt: UInt32,
        viewBytes: Data,
        nonce: Data? = nil,
        padding: (@Sendable (Int) -> Data)? = nil
    ) throws -> Data {
        _ = try mailboxData(mailbox)
        let digest = try validateRequestFields(
            requestID: requestID,
            challenge: challenge,
            expiresAt: expiresAt,
            viewBytes: viewBytes
        )
        let nonceBytes = try resolveNonce(nonce)
        let inner = try CanonicalJSON.encodeObject([
            "v": .int(1),
            "requestId": .string(requestID),
            "challenge": .string(b64URLEncode(challenge)),
            "expiresAt": .int(Int(expiresAt)),
            "view": .string(b64URLEncode(viewBytes)),
            "viewSha256": .string(b64URLEncode(digest)),
        ])
        let frame = try frame(json: inner, frameSize: requestFrameBytes, padding: padding)
        let ciphertext = try aesGCMEncrypt(
            key: keys.requestAEAD,
            nonce: nonceBytes,
            plaintext: frame,
            aad: try requestAAD(mailbox: mailbox, requestID: requestID)
        )
        return try outerEnvelope(nonce: nonceBytes, ciphertext: ciphertext)
    }

    public static func decodeRequest(
        keys: RelayKeys,
        mailbox: String,
        requestID: String,
        envelope: Data
    ) throws -> RelayRequest {
        do {
            let (nonce, ciphertext) = try decodeOuter(
                envelope,
                ciphertextSize: requestFrameBytes + gcmTagBytes
            )
            let frame = try aesGCMDecrypt(
                key: keys.requestAEAD,
                nonce: nonce,
                ciphertext: ciphertext,
                aad: try requestAAD(mailbox: mailbox, requestID: requestID)
            )
            let value = try unframe(frame, frameSize: requestFrameBytes, keys: requestKeys)
            guard case let .int(version) = value["v"], version == 1 else {
                throw RelayCryptoError(message: "unsupported request version")
            }
            guard case let .string(innerID) = value["requestId"], innerID == requestID else {
                throw RelayCryptoError(message: "request id mismatch")
            }
            guard case let .string(challengeText) = value["challenge"] else {
                throw RelayCryptoError(message: "invalid challenge")
            }
            let challenge = try fixedBase64(challengeText, size: 32, name: "challenge")
            guard case let .string(viewText) = value["view"] else {
                throw RelayCryptoError(message: "invalid view")
            }
            let view = try b64URLDecode(viewText)
            guard case let .string(digestText) = value["viewSha256"] else {
                throw RelayCryptoError(message: "invalid view digest")
            }
            let digest = try fixedBase64(digestText, size: 32, name: "view digest")
            guard case let .int(expires) = value["expiresAt"] else {
                throw RelayCryptoError(message: "invalid expiry")
            }
            guard expires > 0, expires <= 0xFFFF_FFFF else {
                throw RelayCryptoError(message: "invalid expiry")
            }
            let calculated = try validateRequestFields(
                requestID: requestID,
                challenge: challenge,
                expiresAt: UInt32(expires),
                viewBytes: view
            )
            guard constantTimeEqual(digest, calculated) else {
                throw RelayCryptoError(message: "view digest mismatch")
            }
            return RelayRequest(
                requestID: requestID,
                challenge: challenge,
                expiresAt: UInt32(expires),
                viewBytes: view,
                viewSHA256: digest
            )
        } catch {
            throw RelayCryptoError.invalidRequestEnvelope
        }
    }
}

private extension InteractionRelayCrypto {
    static func isBase64URLScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F: return true
        default: return false
        }
    }

    static func isHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66: return true
        default: return false
        }
    }

    static func mailboxData(_ mailbox: String) throws -> Data {
        let scalars = Array(mailbox.unicodeScalars)
        guard scalars.count == 19,
              scalars[0] == "v", scalars[1] == "p", scalars[2] == "_"
        else {
            throw RelayCryptoError(message: "invalid mailbox")
        }
        for scalar in scalars.dropFirst(3) {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F, 0x2D: continue
            default: throw RelayCryptoError(message: "invalid mailbox")
            }
        }
        return Data(mailbox.utf8)
    }

    static func requestIDBytes(_ requestID: String) throws -> Data {
        let decoded = try b64URLDecode(requestID)
        guard decoded.count == 16 else {
            throw RelayCryptoError(message: "request id must encode 16 bytes")
        }
        return decoded
    }

    static func requestAAD(mailbox: String, requestID: String) throws -> Data {
        let mailboxBytes = try mailboxData(mailbox)
        _ = try requestIDBytes(requestID)
        var aad = protocolPrefix
        aad.append(UInt8(ascii: "|"))
        aad.append(mailboxBytes)
        aad.append(UInt8(ascii: "|"))
        guard let id = requestID.data(using: .ascii) else {
            throw RelayCryptoError(message: "request id must encode 16 bytes")
        }
        aad.append(id)
        aad.append(Data("|request".utf8))
        return aad
    }

    static func validateRequestFields(
        requestID: String,
        challenge: Data,
        expiresAt: UInt32,
        viewBytes: Data
    ) throws -> Data {
        _ = try requestIDBytes(requestID)
        guard challenge.count == 32 else {
            throw RelayCryptoError(message: "challenge must be 32 bytes")
        }
        guard expiresAt > 0 else {
            throw RelayCryptoError(message: "invalid expiry")
        }
        guard viewBytes.count > 0, viewBytes.count <= maxViewBytes else {
            throw RelayCryptoError(message: "invalid view size")
        }
        return Data(SHA256.hash(data: viewBytes))
    }

    static func resolveNonce(_ nonce: Data?) throws -> Data {
        if let nonce {
            guard nonce.count == gcmNonceBytes else {
                throw RelayCryptoError(message: "nonce must be 12 bytes")
            }
            return nonce
        }
        var bytes = [UInt8](repeating: 0, count: gcmNonceBytes)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes)
    }

    static func paddingBytes(_ padding: (@Sendable (Int) -> Data)?, count: Int) throws -> Data {
        guard count >= 0 else { throw RelayCryptoError(message: "frame overflow") }
        let value: Data
        if let padding {
            value = padding(count)
        } else if count == 0 {
            value = Data()
        } else {
            var bytes = [UInt8](repeating: 0, count: count)
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
            }
            value = Data(bytes)
        }
        guard value.count == count else {
            throw RelayCryptoError(message: "padding has the wrong size")
        }
        return value
    }

    static func frame(json: Data, frameSize: Int, padding: (@Sendable (Int) -> Data)?) throws -> Data {
        let paddingSize = frameSize - 2 - json.count
        if json.count > 0xFFFF || paddingSize < 0 {
            throw RelayCryptoError(message: "frame overflow")
        }
        var out = Data()
        out.reserveCapacity(frameSize)
        out.append(UInt8((json.count >> 8) & 0xFF))
        out.append(UInt8(json.count & 0xFF))
        out.append(json)
        out.append(try paddingBytes(padding, count: paddingSize))
        return out
    }

    static func unframe(_ frame: Data, frameSize: Int, keys: Set<String>) throws -> [String: CanonicalJSON.Value] {
        guard frame.count == frameSize else {
            throw RelayCryptoError(message: "invalid frame size")
        }
        let length = (Int(frame[frame.startIndex]) << 8) | Int(frame[frame.startIndex + 1])
        if length == 0 || length > frameSize - 2 {
            throw RelayCryptoError(message: "invalid frame length")
        }
        let start = frame.index(frame.startIndex, offsetBy: 2)
        let end = frame.index(start, offsetBy: length)
        return try decodeCanonicalObject(Data(frame[start..<end]), keys: keys)
    }

    static func decodeCanonicalObject(_ raw: Data, keys: Set<String>) throws -> [String: CanonicalJSON.Value] {
        guard !raw.isEmpty else { throw RelayCryptoError(message: "invalid JSON") }
        guard case let .success(.object(object)) = CanonicalJSON.parse(raw) else {
            throw RelayCryptoError(message: "invalid JSON")
        }
        guard Set(object.keys) == keys else {
            throw RelayCryptoError(message: "unexpected JSON shape")
        }
        let canonical = try CanonicalJSON.encode(.object(object))
        guard canonical == raw else {
            throw RelayCryptoError(message: "non-canonical JSON")
        }
        return object
    }

    static func outerEnvelope(nonce: Data, ciphertext: Data) throws -> Data {
        try CanonicalJSON.encodeObject([
            "v": .int(1),
            "nonce": .string(b64URLEncode(nonce)),
            "ciphertext": .string(b64URLEncode(ciphertext)),
        ])
    }

    static func decodeOuter(_ envelope: Data, ciphertextSize: Int) throws -> (Data, Data) {
        guard !envelope.isEmpty, envelope.count <= maxEnvelopeBytes else {
            throw RelayCryptoError(message: "invalid envelope size")
        }
        let outer = try decodeCanonicalObject(envelope, keys: outerKeys)
        guard case let .int(version) = outer["v"], version == 1 else {
            throw RelayCryptoError(message: "unsupported envelope version")
        }
        guard case let .string(nonceText) = outer["nonce"],
              case let .string(ciphertextText) = outer["ciphertext"]
        else {
            throw RelayCryptoError(message: "invalid envelope")
        }
        let nonce = try fixedBase64(nonceText, size: gcmNonceBytes, name: "nonce")
        let ciphertext = try fixedBase64(ciphertextText, size: ciphertextSize, name: "ciphertext")
        return (nonce, ciphertext)
    }

    static func fixedBase64(_ text: String, size: Int, name: String) throws -> Data {
        let value = try b64URLDecode(text)
        guard value.count == size else {
            throw RelayCryptoError(message: "\(name) has the wrong size")
        }
        return value
    }

    static func aesGCMEncrypt(key: Data, nonce: Data, plaintext: Data, aad: Data) throws -> Data {
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: try AES.GCM.Nonce(data: nonce),
                authenticating: aad
            )
            return box.ciphertext + box.tag
        } catch {
            throw RelayCryptoError(message: "encryption failed")
        }
    }

    static func aesGCMDecrypt(key: Data, nonce: Data, ciphertext: Data, aad: Data) throws -> Data {
        guard ciphertext.count > gcmTagBytes else {
            throw RelayCryptoError(message: "invalid ciphertext")
        }
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext.dropLast(gcmTagBytes),
            tag: ciphertext.suffix(gcmTagBytes)
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var mismatch: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            mismatch |= left ^ right
        }
        return mismatch == 0
    }
}
