import CryptoKit
import Foundation

public struct RelayCryptoError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    public static let invalidRequestEnvelope = RelayCryptoError(message: "invalid request envelope")
    public static let invalidVerdictEnvelope = RelayCryptoError(message: "invalid verdict envelope")
    public static let invalidStatusEnvelope = RelayCryptoError(message: "invalid status envelope")

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

    public init(requestID: String, challenge: Data, expiresAt: UInt32, viewBytes: Data, viewSHA256: Data) {
        self.requestID = requestID
        self.challenge = challenge
        self.expiresAt = expiresAt
        self.viewBytes = viewBytes
        self.viewSHA256 = viewSHA256
    }
}

public struct RelayVerdict: Sendable, Equatable {
    public let requestID: String
    public let challenge: Data
    public let viewSHA256: Data
    public let verdict: String
    public let mac: Data

    public init(requestID: String, challenge: Data, viewSHA256: Data, verdict: String, mac: Data) {
        self.requestID = requestID
        self.challenge = challenge
        self.viewSHA256 = viewSHA256
        self.verdict = verdict
        self.mac = mac
    }
}

public struct RelayStatus: Sendable, Equatable {
    public let publicationID: UInt64
    public let expiresAt: UInt32
    public let statusBytes: Data
    public let statusSHA256: Data

    public init(publicationID: UInt64, expiresAt: UInt32, statusBytes: Data, statusSHA256: Data) {
        self.publicationID = publicationID
        self.expiresAt = expiresAt
        self.statusBytes = statusBytes
        self.statusSHA256 = statusSHA256
    }
}

public enum InteractionRelayCrypto {
    public static let requestFrameBytes = 2048
    public static let verdictFrameBytes = 1024
    public static let statusFrameBytes = 2816
    public static let maxViewBytes = 640
    public static let maxStatusBytes = 2560
    public static let maxEnvelopeBytes = 4096
    public static let gcmNonceBytes = 12
    public static let gcmTagBytes = 16

    private static let protocolPrefix = Data("vibepulse-ir/v1".utf8)
    private static let salt = Data(SHA256.hash(data: Data("VibePulse interaction relay v1".utf8)))
    private static let outerKeys: Set<String> = ["v", "nonce", "ciphertext"]
    private static let requestKeys: Set<String> = [
        "v", "requestId", "challenge", "expiresAt", "view", "viewSha256",
    ]
    private static let verdictKeys: Set<String> = [
        "v", "requestId", "challenge", "viewSha256", "verdict", "hmac",
    ]
    private static let statusMagic = Data("VPS1".utf8)
    private static let statusHeaderBytes = 50

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

    public static func verdictMAC(
        keys: RelayKeys,
        mailbox: String,
        request: RelayRequest,
        verdict: String
    ) throws -> Data {
        let message = try verdictMACMessage(mailbox: mailbox, request: request, verdict: verdict)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: keys.verdictMAC)))
    }

    public static func encodeVerdict(
        keys: RelayKeys,
        mailbox: String,
        request: RelayRequest,
        verdict: String,
        nonce: Data? = nil,
        padding: (@Sendable (Int) -> Data)? = nil
    ) throws -> Data {
        _ = try verdictMACMessage(mailbox: mailbox, request: request, verdict: verdict)
        let nonceBytes = try resolveNonce(nonce)
        let mac = try verdictMAC(keys: keys, mailbox: mailbox, request: request, verdict: verdict)
        let inner = try CanonicalJSON.encodeObject([
            "v": .int(1),
            "requestId": .string(request.requestID),
            "challenge": .string(b64URLEncode(request.challenge)),
            "viewSha256": .string(b64URLEncode(request.viewSHA256)),
            "verdict": .string(verdict),
            "hmac": .string(b64URLEncode(mac)),
        ])
        let framed = try frame(json: inner, frameSize: verdictFrameBytes, padding: padding)
        let ciphertext = try aesGCMEncrypt(
            key: keys.verdictAEAD,
            nonce: nonceBytes,
            plaintext: framed,
            aad: try verdictAAD(mailbox: mailbox, requestID: request.requestID)
        )
        return try outerEnvelope(nonce: nonceBytes, ciphertext: ciphertext)
    }

    public static func decodeVerdict(
        keys: RelayKeys,
        mailbox: String,
        requestID: String,
        envelope: Data
    ) throws -> RelayVerdict {
        do {
            let (nonce, ciphertext) = try decodeOuter(
                envelope,
                ciphertextSize: verdictFrameBytes + gcmTagBytes
            )
            let framed = try aesGCMDecrypt(
                key: keys.verdictAEAD,
                nonce: nonce,
                ciphertext: ciphertext,
                aad: try verdictAAD(mailbox: mailbox, requestID: requestID)
            )
            let value = try unframe(framed, frameSize: verdictFrameBytes, keys: verdictKeys)
            guard case let .int(version) = value["v"], version == 1 else {
                throw RelayCryptoError(message: "unsupported verdict version")
            }
            guard case let .string(innerID) = value["requestId"], innerID == requestID else {
                throw RelayCryptoError(message: "request id mismatch")
            }
            guard case let .string(challengeText) = value["challenge"] else {
                throw RelayCryptoError(message: "invalid challenge")
            }
            let challenge = try fixedBase64(challengeText, size: 32, name: "challenge")
            guard case let .string(digestText) = value["viewSha256"] else {
                throw RelayCryptoError(message: "invalid view digest")
            }
            let digest = try fixedBase64(digestText, size: 32, name: "view digest")
            guard case let .string(macText) = value["hmac"] else {
                throw RelayCryptoError(message: "invalid verdict HMAC")
            }
            let mac = try fixedBase64(macText, size: 32, name: "verdict HMAC")
            guard case let .string(verdict) = value["verdict"] else {
                throw RelayCryptoError(message: "unsupported verdict")
            }
            _ = try verdictCode(verdict)
            return RelayVerdict(
                requestID: requestID,
                challenge: challenge,
                viewSHA256: digest,
                verdict: verdict,
                mac: mac
            )
        } catch {
            throw RelayCryptoError.invalidVerdictEnvelope
        }
    }

    /// Returns false on any malformed input. Does not throw.
    public static func verifyVerdictMAC(
        keys: RelayKeys,
        mailbox: String,
        request: RelayRequest,
        verdict: RelayVerdict
    ) -> Bool {
        guard verdict.requestID == request.requestID,
              constantTimeEqual(verdict.challenge, request.challenge),
              constantTimeEqual(verdict.viewSHA256, request.viewSHA256)
        else { return false }
        guard let expected = try? verdictMAC(
            keys: keys, mailbox: mailbox, request: request, verdict: verdict.verdict
        ) else { return false }
        return constantTimeEqual(expected, verdict.mac)
    }

    public static func encodeStatus(
        keys: RelayKeys,
        mailbox: String,
        publicationID: UInt64,
        expiresAt: UInt32,
        statusBytes: Data,
        nonce: Data? = nil,
        padding: (@Sendable (Int) -> Data)? = nil
    ) throws -> Data {
        let digest = try validateStatusFields(
            publicationID: publicationID,
            expiresAt: expiresAt,
            statusBytes: statusBytes
        )
        let nonceBytes = try resolveNonce(nonce)
        let framed = try statusFrame(
            publicationID: publicationID,
            expiresAt: expiresAt,
            statusBytes: statusBytes,
            digest: digest,
            padding: padding
        )
        let ciphertext = try aesGCMEncrypt(
            key: keys.statusAEAD,
            nonce: nonceBytes,
            plaintext: framed,
            aad: try statusAAD(mailbox: mailbox)
        )
        return try outerEnvelope(nonce: nonceBytes, ciphertext: ciphertext)
    }

    public static func decodeStatus(
        keys: RelayKeys,
        mailbox: String,
        envelope: Data
    ) throws -> RelayStatus {
        do {
            let (nonce, ciphertext) = try decodeOuter(
                envelope,
                ciphertextSize: statusFrameBytes + gcmTagBytes
            )
            let framed = try aesGCMDecrypt(
                key: keys.statusAEAD,
                nonce: nonce,
                ciphertext: ciphertext,
                aad: try statusAAD(mailbox: mailbox)
            )
            let bytes = [UInt8](framed)
            guard bytes.count == statusFrameBytes, Data(bytes.prefix(4)) == statusMagic else {
                throw RelayCryptoError(message: "invalid status frame")
            }
            let publicationID = readBigEndian(bytes, start: 4, width: 8)
            let expires = readBigEndian(bytes, start: 12, width: 4)
            let statusLength = Int(readBigEndian(bytes, start: 16, width: 2))
            if statusLength > statusFrameBytes - statusHeaderBytes {
                throw RelayCryptoError(message: "invalid status length")
            }
            let digest = Data(bytes[18..<50])
            let statusBytes = Data(bytes[50..<(50 + statusLength)])
            guard expires > 0, expires <= UInt64(UInt32.max) else {
                throw RelayCryptoError(message: "invalid expiry")
            }
            let calculated = try validateStatusFields(
                publicationID: publicationID,
                expiresAt: UInt32(expires),
                statusBytes: statusBytes
            )
            guard constantTimeEqual(digest, calculated) else {
                throw RelayCryptoError(message: "status digest mismatch")
            }
            return RelayStatus(
                publicationID: publicationID,
                expiresAt: UInt32(expires),
                statusBytes: statusBytes,
                statusSHA256: digest
            )
        } catch {
            throw RelayCryptoError.invalidStatusEnvelope
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
        try scopedAAD(mailbox: mailbox, requestID: requestID, suffix: "|request")
    }

    static func verdictAAD(mailbox: String, requestID: String) throws -> Data {
        try scopedAAD(mailbox: mailbox, requestID: requestID, suffix: "|verdict")
    }

    static func statusAAD(mailbox: String) throws -> Data {
        let mailboxBytes = try mailboxData(mailbox)
        var aad = protocolPrefix
        aad.append(UInt8(ascii: "|"))
        aad.append(mailboxBytes)
        aad.append(Data("|status".utf8))
        return aad
    }

    static func scopedAAD(mailbox: String, requestID: String, suffix: String) throws -> Data {
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
        aad.append(Data(suffix.utf8))
        return aad
    }

    static func verdictCode(_ verdict: String) throws -> UInt8 {
        switch verdict {
        case "approve": return 1
        case "deny": return 2
        case "terminal": return 3
        case "panic": return 4
        default: throw RelayCryptoError(message: "unsupported verdict")
        }
    }

    static func verdictMACMessage(mailbox: String, request: RelayRequest, verdict: String) throws -> Data {
        let calculated = try validateRequestFields(
            requestID: request.requestID,
            challenge: request.challenge,
            expiresAt: request.expiresAt,
            viewBytes: request.viewBytes
        )
        guard constantTimeEqual(calculated, request.viewSHA256) else {
            throw RelayCryptoError(message: "invalid relay request digest")
        }
        let mailboxBytes = try mailboxData(mailbox)
        let code = try verdictCode(verdict)
        let requestID = try requestIDBytes(request.requestID)
        var message = Data("vibepulse-ir-verdict-v1".utf8)
        message.append(0)
        message.append(UInt8((mailboxBytes.count >> 8) & 0xFF))
        message.append(UInt8(mailboxBytes.count & 0xFF))
        message.append(mailboxBytes)
        message.append(requestID)
        message.append(request.challenge)
        message.append(request.viewSHA256)
        message.append(code)
        return message
    }

    static func validateStatusFields(publicationID: UInt64, expiresAt: UInt32, statusBytes: Data) throws -> Data {
        guard publicationID > 0 else {
            throw RelayCryptoError(message: "invalid publication id")
        }
        guard expiresAt > 0 else {
            throw RelayCryptoError(message: "invalid expiry")
        }
        guard statusBytes.count > 0, statusBytes.count <= maxStatusBytes else {
            throw RelayCryptoError(message: "invalid status size")
        }
        return Data(SHA256.hash(data: statusBytes))
    }

    static func statusFrame(
        publicationID: UInt64,
        expiresAt: UInt32,
        statusBytes: Data,
        digest: Data,
        padding: (@Sendable (Int) -> Data)?
    ) throws -> Data {
        let paddingSize = statusFrameBytes - statusHeaderBytes - statusBytes.count
        guard paddingSize >= 0 else { throw RelayCryptoError(message: "frame overflow") }
        var frame = Data()
        frame.reserveCapacity(statusFrameBytes)
        frame.append(statusMagic)
        appendBigEndian(publicationID, width: 8, to: &frame)
        appendBigEndian(UInt64(expiresAt), width: 4, to: &frame)
        appendBigEndian(UInt64(statusBytes.count), width: 2, to: &frame)
        frame.append(digest)
        frame.append(statusBytes)
        frame.append(try paddingBytes(padding, count: paddingSize))
        guard frame.count == statusFrameBytes else {
            throw RelayCryptoError(message: "invalid status frame")
        }
        return frame
    }

    static func appendBigEndian(_ value: UInt64, width: Int, to data: inout Data) {
        var shift = (width - 1) * 8
        for _ in 0..<width {
            data.append(UInt8((value >> shift) & 0xFF))
            shift -= 8
        }
    }

    static func readBigEndian(_ bytes: [UInt8], start: Int, width: Int) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<width {
            value = (value << 8) | UInt64(bytes[start + offset])
        }
        return value
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
