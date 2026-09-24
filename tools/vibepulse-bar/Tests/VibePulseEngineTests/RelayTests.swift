import CryptoKit
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
        XCTAssertEqual(hexString(keys.requestAEAD), expected?["requestKeyHex"] as? String)
        XCTAssertEqual(hexString(keys.verdictAEAD), expected?["verdictKeyHex"] as? String)
        XCTAssertEqual(hexString(keys.verdictMAC), expected?["verdictMacKeyHex"] as? String)
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

    func testVerdictAndStatusMatchKnownAnswers() throws {
        let vector = try loadVector()
        let inputs = vector["inputs"] as? [String: Any]
        let expected = vector["expected"] as? [String: Any]
        let mailbox = inputs?["mailbox"] as? String ?? ""
        let requestID = inputs?["requestId"] as? String ?? ""
        let keys = try InteractionRelayCrypto.deriveKeys(
            deviceKey: try InteractionRelayCrypto.decodeDeviceKey(inputs?["deviceKeyHex"] as? String ?? ""),
            mailbox: mailbox
        )
        let requestEnvelope = try InteractionRelayCrypto.encodeRequest(
            keys: keys,
            mailbox: mailbox,
            requestID: requestID,
            challenge: hex(inputs?["challengeHex"] as? String ?? ""),
            expiresAt: UInt32((inputs?["expiresAt"] as? NSNumber)?.uint32Value ?? 0),
            viewBytes: Data((inputs?["viewUtf8"] as? String ?? "").utf8),
            nonce: hex(inputs?["requestNonceHex"] as? String ?? ""),
            padding: { Data(repeating: 0xA5, count: $0) }
        )
        let request = try InteractionRelayCrypto.decodeRequest(
            keys: keys, mailbox: mailbox, requestID: requestID, envelope: requestEnvelope)
        let macs = [
            "approve": "3b060a291ef9134285b2cde0aee3c6db3002c7b5a6a143a96b1fe84dbe825a5d",
            "deny": "ae86c86a73a615bd76cdd9b502c8bda7e7e5f3859974c28e3eb0fd06f39352a0",
            "terminal": "9a6ecfd764e77cf95ea603f2470517fdacff289c800bea1aa648fc0cb2777a5a",
            "panic": "cb21b1ee5a6840bc4375c10965b9bcd00457fe3db2e9cd48991dd084351a94f7",
        ]
        for (verdict, digest) in macs {
            let mac = try InteractionRelayCrypto.verdictMAC(
                keys: keys, mailbox: mailbox, request: request, verdict: verdict)
            XCTAssertEqual(hexString(mac), digest, verdict)
        }
        let verdictEnvelope = try InteractionRelayCrypto.encodeVerdict(
            keys: keys, mailbox: mailbox, request: request, verdict: "approve",
            nonce: hex(inputs?["verdictNonceHex"] as? String ?? ""),
            padding: { Data(repeating: 0xA5, count: $0) }
        )
        XCTAssertEqual(verdictEnvelope, Data((expected?["verdictEnvelopeUtf8"] as? String ?? "").utf8))
        let verdict = try InteractionRelayCrypto.decodeVerdict(
            keys: keys, mailbox: mailbox, requestID: requestID, envelope: verdictEnvelope)
        XCTAssertEqual(verdict.verdict, "approve")
        XCTAssertEqual(InteractionRelayCrypto.b64URLEncode(verdict.mac), expected?["verdictHmacBase64url"] as? String)
        XCTAssertTrue(InteractionRelayCrypto.verifyVerdictMAC(
            keys: keys, mailbox: mailbox, request: request, verdict: verdict))
        let bad = RelayVerdict(
            requestID: verdict.requestID, challenge: verdict.challenge, viewSHA256: verdict.viewSHA256,
            verdict: verdict.verdict, mac: Data(repeating: 0, count: 32))
        XCTAssertFalse(InteractionRelayCrypto.verifyVerdictMAC(
            keys: keys, mailbox: mailbox, request: request, verdict: bad))

        let statusVector = try loadVector(named: "agent-status-relay-v1.json")
        let statusInputs = statusVector["inputs"] as? [String: Any]
        let statusExpected = statusVector["expected"] as? [String: Any]
        let statusMailbox = statusInputs?["mailbox"] as? String ?? ""
        let statusKeys = try InteractionRelayCrypto.deriveKeys(
            deviceKey: try InteractionRelayCrypto.decodeDeviceKey(statusInputs?["deviceKeyHex"] as? String ?? ""),
            mailbox: statusMailbox
        )
        XCTAssertEqual(hexString(statusKeys.statusAEAD), statusExpected?["statusKeyHex"] as? String)
        let statusEnvelope = try InteractionRelayCrypto.encodeStatus(
            keys: statusKeys,
            mailbox: statusMailbox,
            publicationID: (statusInputs?["publicationId"] as? NSNumber)?.uint64Value ?? 0,
            expiresAt: UInt32((statusInputs?["expiresAt"] as? NSNumber)?.uint32Value ?? 0),
            statusBytes: Data((statusInputs?["statusUtf8"] as? String ?? "").utf8),
            nonce: hex(statusInputs?["statusNonceHex"] as? String ?? ""),
            padding: { Data(repeating: 0xA5, count: $0) }
        )
        XCTAssertEqual(statusEnvelope, Data((statusExpected?["statusEnvelopeUtf8"] as? String ?? "").utf8))
        let status = try InteractionRelayCrypto.decodeStatus(
            keys: statusKeys, mailbox: statusMailbox, envelope: statusEnvelope)
        XCTAssertEqual(status.publicationID, (statusInputs?["publicationId"] as? NSNumber)?.uint64Value ?? 0)
        XCTAssertEqual(status.statusBytes, Data((statusInputs?["statusUtf8"] as? String ?? "").utf8))
    }

    func testPublisherJSONAndSendRules() throws {
        let body = try CanonicalJSON.encodePublisher(.object([
            "b": .int(1),
            "a": .object(["y": .int(1), "x": .array([.int(1), .int(2)])]),
        ]))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"a": {"x": [1, 2], "y": 1}, "b": 1}"#)
        let left = try NumbersPublish.fingerprint(.object(["b": .int(1), "a": .int(2)]))
        let right = try NumbersPublish.fingerprint(.object(["a": .int(2), "b": .int(1)]))
        XCTAssertEqual(left, right)
        XCTAssertTrue(NumbersPublish.shouldSend(
            lastFingerprint: nil, lastSentAt: 0, fingerprint: "a", now: 0, minInterval: 300))
        XCTAssertFalse(NumbersPublish.shouldSend(
            lastFingerprint: "a", lastSentAt: 0, fingerprint: "b", now: 10, minInterval: 300))
        XCTAssertTrue(NumbersPublish.shouldSend(
            lastFingerprint: "a", lastSentAt: 0, fingerprint: "b", now: 300, minInterval: 300))
        XCTAssertTrue(NumbersPublish.shouldSend(
            lastFingerprint: "a", lastSentAt: 0, fingerprint: "a", now: 300, minInterval: 300))
        XCTAssertTrue(NumbersPublish.isStartupPlaceholder(.object([
            "usageTotals": .object(["placeholder": .bool(true)]),
        ])))
        XCTAssertFalse(NumbersPublish.isStartupPlaceholder(.object([
            "usageTotals": .object(["placeholder": .int(1)]),
        ])))
        XCTAssertEqual(NumbersPublish.staleFields(.object([
            "claudeWeekStale": .bool(true),
            "codexWeekStale": .bool(false),
            "noteStale": .string("true"),
        ])), ["claudeWeekStale"])

        let payloads = PublisherPayloads()
        var calls: [PublishRequest] = []
        var succeed = false
        var now = 1_000.0
        let publisher = NumbersPublisher(
            relayURL: "https://relay.example/u/secret/",
            machine: "workstation",
            producers: [
                ("/api/tokens", { payloads.tokens }),
                ("/api/github", { payloads.github }),
            ],
            post: { request in
                calls.append(request)
                return succeed
            },
            clock: { now }
        )
        XCTAssertEqual(publisher.publishOnce(), 0)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].url, "https://relay.example/u/secret/api/github")
        XCTAssertEqual(calls[0].userAgent, NumbersPublish.userAgent)
        XCTAssertTrue(calls[0].userAgent.hasPrefix("vibepulse-publisher/"))
        XCTAssertEqual(calls[0].publisher, "workstation")
        XCTAssertEqual(calls[0].contentType, "application/json")
        succeed = true
        XCTAssertEqual(publisher.publishOnce(), 1)
        payloads.tokens = .object([
            "usageTotals": .object(["placeholder": .bool(false)]),
            "claudeWeekStale": .bool(true),
            "n": .int(1),
        ])
        now = 1_100
        XCTAssertEqual(publisher.publishOnce(), 1)
        let firstTokens = calls.last?.body
        now = 1_200
        payloads.tokens = .object([
            "usageTotals": .object(["placeholder": .bool(false)]),
            "claudeWeekStale": .bool(false),
            "n": .int(2),
        ])
        XCTAssertEqual(publisher.publishOnce(), 1)
        XCTAssertNotEqual(calls.last?.body, firstTokens)
        now = 1_250
        payloads.tokens = .object([
            "usageTotals": .object(["placeholder": .bool(false)]),
            "claudeWeekStale": .bool(false),
            "n": .int(3),
        ])
        let before = calls.count
        XCTAssertEqual(publisher.publishOnce(), 0)
        XCTAssertEqual(calls.count, before)
    }

    func testGitHubMonitorUsesInjectedHTTP() throws {
        let script = GitHubScript()
        var now = 10_000.0
        let monitor = try GitHubMonitor(
            repo: " niclas/vibepulse ",
            token: " ghp_test ",
            transport: { try script.fetch($0) },
            clock: { now },
            wallClock: { 1_700_000_000 }
        )
        XCTAssertEqual(monitor.repo, "niclas/vibepulse")
        for bad in ["", "owner", "https://github.com/a/b", "a/b/c", "a b/repo"] {
            XCTAssertThrowsError(try GitHubMonitor.normalizeRepo(bad))
        }
        script.responses = [repoJSON(stars: 10, forks: 2)]
        XCTAssertTrue(monitor.pollOnce())
        XCTAssertEqual(script.calls[0].url, "https://api.github.com/repos/niclas/vibepulse")
        XCTAssertEqual(script.calls[0].headers["Accept"], GitHubMonitor.accept)
        XCTAssertEqual(script.calls[0].headers["User-Agent"], GitHubMonitor.userAgent)
        XCTAssertEqual(script.calls[0].headers["X-GitHub-Api-Version"], GitHubMonitor.apiVersion)
        XCTAssertEqual(script.calls[0].headers["Authorization"], "Bearer ghp_test")
        XCTAssertNotEqual(script.calls[0].headers["Accept"], "application/vnd.github.star+json")
        var snap = monitor.snapshot()
        XCTAssertEqual(snap.stars, 10)
        XCTAssertEqual(snap.forks, 2)
        XCTAssertEqual(snap.project, "vibepulse")
        XCTAssertEqual(snap.stale, false)
        XCTAssertNil(snap.event)

        let events = Data(#"[{"type":"PushEvent"},{"type":"WatchEvent","actor":{"login":""},"created_at":"2026-08-14T18:02:00Z"},{"type":"WatchEvent","actor":{"login":"octocat"},"created_at":"2026-08-14T20:02:00+02:00"}]"#.utf8)
        script.responses = [repoJSON(stars: 11, forks: 2), GitHubHTTPResponse(status: 200, body: events)]
        now = 10_010
        XCTAssertTrue(monitor.pollOnce())
        XCTAssertTrue(script.calls.last?.url.contains("/events?per_page=30") == true)
        XCTAssertEqual(script.calls.last?.headers["Accept"], "application/vnd.github+json")
        snap = monitor.snapshot()
        XCTAssertEqual(snap.event, GitHubEvent(eventID: "2026-08-14T18:02:00Z", actor: "octocat", eventStars: 11))
        now = 10_610
        XCTAssertNotNil(monitor.snapshot().event)
        now = 10_611
        XCTAssertNil(monitor.snapshot().event)
        XCTAssertEqual(monitor.snapshot().stars, 11)
        now = 10_311
        XCTAssertEqual(monitor.snapshot().stale, true)

        script.responses = [GitHubHTTPResponse(status: 403, headers: ["Retry-After": "900"], body: Data())]
        XCTAssertFalse(monitor.pollOnce())
        XCTAssertEqual(monitor.nextPollAt, now + 900)
        XCTAssertEqual(monitor.snapshot().stars, 11)
        XCTAssertEqual(monitor.snapshot().stale, true)

        script.responses = [GitHubHTTPResponse(status: 500, body: Data("nope".utf8))]
        let failedAt = now
        XCTAssertFalse(monitor.pollOnce())
        XCTAssertEqual(monitor.nextPollAt, failedAt + GitHubMonitor.failureBackoff)

        script.responses = [GitHubHTTPResponse(
            status: 200,
            body: Data(#"{"private":false,"stargazers_count":true,"forks_count":1,"name":"vibepulse"}"#.utf8))]
        XCTAssertFalse(monitor.pollOnce())
        script.responses = [GitHubHTTPResponse(
            status: 200,
            body: Data(#"{"stargazers_count":3,"forks_count":1,"name":"vibepulse"}"#.utf8))]
        XCTAssertFalse(monitor.pollOnce())

        let anon = GitHubScript()
        anon.responses = [repoJSON(stars: 1, forks: 0)]
        let plain = try GitHubMonitor(
            repo: "niclas/vibepulse", transport: { try anon.fetch($0) }, clock: { 1 }, wallClock: { 1 })
        XCTAssertTrue(plain.pollOnce())
        XCTAssertNil(anon.calls[0].headers["Authorization"])
        let disabled = try CanonicalJSON.encode(GitHubMonitor.disabledSnapshot().value())
        XCTAssertEqual(String(decoding: disabled, as: UTF8.self), #"{"enabled":false,"v":1}"#)
    }

    func testDiscoveryStubAdvertisesServiceType() throws {
        XCTAssertEqual(DiscoveryService.serviceType, "_vibepulse._tcp.local.")
        XCTAssertEqual(DiscoveryService.bonjourRegtype, "_vibepulse._tcp")
        XCTAssertEqual(DiscoveryService.protocolVersion, "1")
        XCTAssertEqual(safeDNSLabel("PC å Ä / Test"), "pc-test")
        XCTAssertEqual(safeDNSLabel("---"), "host")
        XCTAssertEqual(safeDNSLabel(String(repeating: "x", count: 100)).count, 48)
        XCTAssertEqual(
            routableIPv4Addresses(["10.0.0.2", "127.0.0.1", "10.0.0.10", "169.254.1.1", "0.0.0.0", "10.0.0.10"]),
            [Data([10, 0, 0, 10]), Data([10, 0, 0, 2])]
        )
        let missing = DiscoveryAdvertiser()
        XCTAssertFalse(missing.start(port: 8737))
        XCTAssertEqual(missing.status, "unavailable")
        XCTAssertEqual(missing.reason, "dependency-missing")

        let registrar = RecordingRegistrar()
        let badPort = DiscoveryAdvertiser(registrar: registrar)
        XCTAssertFalse(badPort.start(port: 0))
        XCTAssertEqual(badPort.reason, "invalid-port")
        let empty = DiscoveryAdvertiser(addresses: { [] }, registrar: registrar)
        XCTAssertFalse(empty.start(port: 8737))
        XCTAssertEqual(empty.reason, "no-lan-address")

        let advertiser = DiscoveryAdvertiser(
            addresses: { ["10.0.0.2", "127.0.0.1", "10.0.0.10"] },
            hostname: { "PC å Ä / Test" },
            registrar: registrar
        )
        XCTAssertTrue(advertiser.start(port: 8737))
        XCTAssertEqual(advertiser.status, "ready")
        XCTAssertNil(advertiser.reason)
        let ad = try XCTUnwrap(registrar.advertisements.first)
        XCTAssertEqual(ad.serviceType, DiscoveryService.serviceType)
        XCTAssertEqual(ad.instanceName, "VibePulse-pc-test._vibepulse._tcp.local.")
        XCTAssertEqual(ad.serverName, "vibepulse-pc-test.local.")
        XCTAssertEqual(ad.port, 8737)
        XCTAssertEqual(ad.text, ["v": "1"])
        XCTAssertEqual(ad.addresses, [Data([10, 0, 0, 10]), Data([10, 0, 0, 2])])
        advertiser.stop()
        XCTAssertEqual(registrar.stopped, 1)
        advertiser.stop()
        XCTAssertEqual(registrar.stopped, 1)

        registrar.failure = DiscoveryBoom()
        XCTAssertFalse(advertiser.start(port: 8737))
        XCTAssertEqual(advertiser.status, "error")
        XCTAssertEqual(advertiser.reason, "DiscoveryBoom")
    }

    func testStopSkipsTheNextRelayCycle() throws {
        let token = InteractionRelayCrypto.b64URLEncode(Data(repeating: 0x11, count: 32))
        let device = String(repeating: "11", count: 32)
        let mailbox = "vp_A1b2C3d4E5f6G7h8"
        let script = ScriptRelay { request in
            if request.method == "GET" {
                return RelayHTTPResponse(status: 204, headers: [("Cache-Control", "no-store")], body: Data())
            }
            return RelayHTTPResponse(status: 201, headers: [("Cache-Control", "no-store")], body: Data())
        }
        let relay = try InteractionRelay(
            store: MemoryRelayStore(), baseURL: "https://relay.example", mailbox: mailbox,
            macToken: token, deviceKeyHex: device, transport: { try script.send($0) },
            now: { 1_000 }, randomBytes: { Data(repeating: 0x5A, count: $0) }, jitter: { 0 }
        )
        relay.onPark(makeJob(idByte: 1))
        relay.runOnce()
        XCTAssertEqual(script.calls.map(\.method), ["PUT", "GET"])
        relay.stop()
        relay.onPark(makeJob(idByte: 2))
        relay.runOnce()
        relay.stop()
        relay.runOnce()
        XCTAssertEqual(script.calls.count, 2)

        let coldScript = ScriptRelay { _ in
            RelayHTTPResponse(status: 201, headers: [("Cache-Control", "no-store")], body: Data())
        }
        let cold = try InteractionRelay(
            store: MemoryRelayStore(), baseURL: "https://relay.example", mailbox: mailbox,
            macToken: token, deviceKeyHex: device, transport: { try coldScript.send($0) },
            now: { 1_000 }, randomBytes: { Data(repeating: 0x5A, count: $0) }, jitter: { 0 }
        )
        cold.stop()
        cold.onPark(makeJob(idByte: 3))
        cold.runOnce()
        cold.stop()
        cold.runOnce()
        XCTAssertTrue(coldScript.calls.isEmpty)

        var moment = 1_000.0
        let statusScript = ScriptRelay { _ in
            RelayHTTPResponse(status: 201, headers: [("Cache-Control", "no-store")], body: Data())
        }
        let status = try InteractionRelay(
            store: nil, baseURL: "https://relay.example", mailbox: mailbox, macToken: token,
            deviceKeyHex: device, transport: { try statusScript.send($0) },
            publishInteractions: false, publishAgentStatus: true,
            statusSource: { .object(["v": .int(2)]) },
            now: { moment }, wall: { 50_000 },
            randomBytes: { Data(repeating: 0x5A, count: $0) }, jitter: { 0 }
        )
        status.runOnce()
        XCTAssertEqual(statusScript.calls.count, 1)
        status.stop()
        moment = 1_006
        status.runOnce()
        status.stop()
        status.runOnce()
        XCTAssertEqual(statusScript.calls.count, 1)
    }

    func testStopSkipsTheNextNumbersPost() {
        var posts = 0
        var now = 5_000.0
        let payload = CanonicalJSON.Value.object([
            "usageTotals": .object(["placeholder": .bool(false)]),
            "n": .int(1),
        ])
        let publisher = NumbersPublisher(
            relayURL: "https://relay.example/u/secret/",
            machine: "workstation",
            producers: [("/api/tokens", { payload })],
            post: { _ in
                posts += 1
                return true
            },
            clock: { now }
        )
        XCTAssertEqual(publisher.publishOnce(), 1)
        now = 5_300
        publisher.stop()
        XCTAssertEqual(publisher.publishOnce(), 0)
        publisher.stop()
        now = 9_000
        XCTAssertEqual(publisher.publishOnce(), 0)
        XCTAssertEqual(posts, 1)

        var idlePosts = 0
        let idle = NumbersPublisher(
            relayURL: "https://relay.example/u/secret",
            machine: "workstation",
            producers: [("/api/tokens", { payload })],
            post: { _ in
                idlePosts += 1
                return true
            },
            clock: { 1 }
        )
        idle.stop()
        XCTAssertEqual(idle.publishOnce(), 0)
        idle.stop()
        XCTAssertEqual(idle.publishOnce(), 0)
        XCTAssertEqual(idlePosts, 0)
    }

    func testStopSkipsTheNextGitHubPoll() throws {
        let script = GitHubScript()
        script.responses = [repoJSON(stars: 3, forks: 1), repoJSON(stars: 8, forks: 1)]
        let monitor = try GitHubMonitor(
            repo: "niclas/vibepulse",
            transport: { try script.fetch($0) },
            clock: { 20 },
            wallClock: { 20 }
        )
        XCTAssertTrue(monitor.pollOnce())
        XCTAssertEqual(script.calls.count, 1)
        let due = monitor.nextPollAt
        monitor.stop()
        XCTAssertFalse(monitor.pollOnce())
        monitor.stop()
        XCTAssertFalse(monitor.pollOnce())
        XCTAssertEqual(script.calls.count, 1)
        XCTAssertEqual(monitor.snapshot().stars, 3)
        XCTAssertNil(monitor.lastError)
        XCTAssertEqual(monitor.nextPollAt, due)

        let coldScript = GitHubScript()
        coldScript.responses = [repoJSON(stars: 1, forks: 0)]
        let cold = try GitHubMonitor(
            repo: "niclas/vibepulse",
            transport: { try coldScript.fetch($0) },
            clock: { 1 },
            wallClock: { 1 }
        )
        cold.stop()
        XCTAssertFalse(cold.pollOnce())
        cold.stop()
        XCTAssertFalse(cold.pollOnce())
        XCTAssertTrue(coldScript.calls.isEmpty)
        XCTAssertEqual(cold.nextPollAt, 0)
        XCTAssertNil(cold.lastError)
    }

    func testDiscoveryStopBeforeStartDoesNotUnregister() throws {
        let missing = DiscoveryAdvertiser()
        missing.stop()
        missing.stop()
        XCTAssertEqual(missing.status, "off")

        let registrar = RecordingRegistrar()
        let idle = DiscoveryAdvertiser(
            addresses: { ["10.0.0.4"] },
            hostname: { "host" },
            registrar: registrar
        )
        idle.stop()
        idle.stop()
        XCTAssertEqual(registrar.stopped, 0)
        let rejected = DiscoveryAdvertiser(registrar: registrar)
        XCTAssertFalse(rejected.start(port: 0))
        rejected.stop()
        XCTAssertEqual(registrar.stopped, 0)

        XCTAssertTrue(idle.start(port: 8741))
        idle.stop()
        XCTAssertEqual(registrar.stopped, 1)
        idle.stop()
        XCTAssertEqual(registrar.stopped, 1)
        XCTAssertTrue(idle.start(port: 8741))
        idle.stop()
        XCTAssertEqual(registrar.stopped, 2)
    }

    func testRelayOriginAndInteractionCycle() throws {
        for sample in [
            "http://relay.example", "https://user@relay.example",
            "https://relay.example/path", "https://relay.example?x=1",
        ] {
            XCTAssertThrowsError(try RelayOrigin.parse(sample))
        }
        let lowered = try RelayOrigin.parse("https://Relay.Example")
        XCTAssertEqual(lowered.origin, "https://relay.example")
        XCTAssertEqual(lowered.port, 443)
        XCTAssertEqual(try RelayOrigin.parse("https://relay.example:8443").origin, "https://relay.example:8443")
        XCTAssertEqual(try RelayOrigin.parse("https://relay.example:0").port, 443)

        let token = InteractionRelayCrypto.b64URLEncode(Data(repeating: 0x11, count: 32))
        XCTAssertEqual(token, "ERERERERERERERERERERERERERERERERERERERERERE")
        let device = String(repeating: "11", count: 32)
        let mailbox = "vp_A1b2C3d4E5f6G7h8"
        let job = makeJob(idByte: 7)
        let store = MemoryRelayStore()
        store.job = job
        let keys = try InteractionRelayCrypto.deriveKeys(
            deviceKey: try InteractionRelayCrypto.decodeDeviceKey(device), mailbox: mailbox)
        let request = RelayRequest(
            requestID: job.requestID, challenge: job.challenge, expiresAt: job.expiresAt,
            viewBytes: job.viewBytes, viewSHA256: job.viewSHA256)
        let verdictEnvelope = try InteractionRelayCrypto.encodeVerdict(
            keys: keys, mailbox: mailbox, request: request, verdict: "approve",
            nonce: Data(repeating: 0x44, count: 12), padding: { Data(repeating: 0xA5, count: $0) })
        guard case let .success(verdictValue) = CanonicalJSON.parse(verdictEnvelope) else {
            return XCTFail("verdict envelope did not parse")
        }
        let verdictBody = try CanonicalJSON.encode(.object([
            "verdicts": .array([.object([
                "requestId": .string(job.requestID),
                "verdictAtMs": .int(1_700_000_000_000),
                "envelope": verdictValue,
            ])]),
        ]))
        var audits: [(String, [String: RelayAuditField])] = []
        let script = ScriptRelay { request in
            if request.method == "GET" {
                return RelayHTTPResponse(status: 200, headers: [
                    ("Cache-Control", "no-store"),
                    ("Content-Type", "application/json; charset=utf-8"),
                ], body: verdictBody)
            }
            if request.method == "DELETE" {
                return RelayHTTPResponse(status: 204, headers: [("Cache-Control", "no-store")], body: Data())
            }
            return RelayHTTPResponse(status: 201, headers: [("Cache-Control", "no-store")], body: Data())
        }
        var moment = 1_000.0
        let relay = try InteractionRelay(
            store: store, baseURL: "https://relay.example/", mailbox: mailbox, macToken: token,
            deviceKeyHex: device, transport: { try script.send($0) },
            now: { moment }, wall: { 50_000 },
            randomBytes: { Data(repeating: 0x5A, count: $0) }, jitter: { 0 },
            audit: { audits.append(($0, $1)) }
        )
        XCTAssertTrue(store.listener === relay)
        relay.onPark(job)
        relay.runOnce()
        XCTAssertEqual(script.calls.map(\.method), ["PUT", "GET"])
        XCTAssertEqual(
            script.calls[0].url,
            "https://relay.example/v1/mailboxes/\(mailbox)/requests/\(job.requestID)")
        XCTAssertEqual(script.calls[0].headers.first?.1, "Bearer \(token)")
        XCTAssertTrue(script.calls[0].headers.contains { $0 == ("Accept", "application/json") })
        XCTAssertTrue(script.calls[0].headers.contains { $0 == ("Content-Type", "application/json") })
        XCTAssertFalse(script.calls[1].headers.contains { $0.0 == "Content-Type" })
        XCTAssertEqual(script.calls[0].connectTimeout, 2)
        XCTAssertEqual(script.calls[0].readTimeout, 5)
        XCTAssertTrue(store.accepted)
        let blob = audits.map { pair in
            pair.1.values.map { field -> String in
                switch field {
                case let .text(text): return text
                case let .number(number): return String(number)
                }
            }.joined(separator: " ")
        }.joined(separator: " ")
        XCTAssertFalse(blob.contains(token))
        XCTAssertFalse(blob.contains(mailbox))
        XCTAssertFalse(blob.contains(job.requestID))

        let removal = ScriptRelay { _ in
            RelayHTTPResponse(status: 204, headers: [("Cache-Control", "no-store")], body: Data())
        }
        let remover = try InteractionRelay(
            store: MemoryRelayStore(), baseURL: "https://relay.example", mailbox: mailbox,
            macToken: token, deviceKeyHex: device, transport: { try removal.send($0) },
            now: { moment }, randomBytes: { Data(repeating: 1, count: $0) }, jitter: { 0 }
        )
        let other = makeJob(idByte: 8)
        remover.onRemove(requestID: other.requestID, reason: "timeout")
        remover.runOnce()
        XCTAssertEqual(removal.calls.map(\.method), ["DELETE"])
        XCTAssertTrue(removal.calls[0].url.hasSuffix("/requests/\(other.requestID)"))
        XCTAssertFalse(removal.calls[0].headers.contains { $0.0 == "Content-Type" })
    }

    func testStatusRelayStripsPendingAndRetriesCiphertext() throws {
        let token = InteractionRelayCrypto.b64URLEncode(Data(repeating: 0x11, count: 32))
        let device = String(repeating: "22", count: 32)
        let mailbox = "vp_A1b2C3d4E5f6G7h8"
        let keys = try InteractionRelayCrypto.deriveKeys(
            deviceKey: try InteractionRelayCrypto.decodeDeviceKey(device), mailbox: mailbox)
        var moment = 1_000.0
        var fail = true
        let script = ScriptRelay { request in
            if fail {
                fail = false
                return RelayHTTPResponse(status: 500, headers: [("Cache-Control", "no-store")], body: Data())
            }
            return RelayHTTPResponse(status: 201, headers: [("Cache-Control", "no-store")], body: Data())
        }
        let relay = try InteractionRelay(
            store: nil, baseURL: "https://relay.example", mailbox: mailbox, macToken: token,
            deviceKeyHex: device, transport: { try script.send($0) },
            publishInteractions: false, publishAgentStatus: true,
            statusSource: {
                .object([
                    "pending": .string("secret question"),
                    "seq": .int(7),
                    "v": .int(2),
                ])
            },
            now: { moment }, wall: { 50_000 },
            randomBytes: { Data(repeating: 0x5A, count: $0) }, jitter: { 0 }
        )
        relay.runOnce()
        moment = 1_000.5
        relay.runOnce()
        XCTAssertEqual(script.calls.count, 2)
        XCTAssertEqual(script.calls[0].body, script.calls[1].body)
        XCTAssertEqual(script.calls[1].method, "PUT")
        XCTAssertTrue(script.calls[1].url.hasSuffix("/v1/mailboxes/\(mailbox)/status"))
        let decoded = try InteractionRelayCrypto.decodeStatus(
            keys: keys, mailbox: mailbox, envelope: script.calls[1].body)
        XCTAssertEqual(decoded.publicationID, 50_000_000)
        XCTAssertEqual(decoded.expiresAt, 50_015)
        let text = String(decoding: decoded.statusBytes, as: UTF8.self)
        XCTAssertEqual(text, #"{"seq":7,"v":2}"#)
        XCTAssertFalse(text.contains("pending"))
        relay.runOnce()
        XCTAssertEqual(script.calls.count, 2)
        moment = 1_005.5
        relay.runOnce()
        let next = try InteractionRelayCrypto.decodeStatus(
            keys: keys, mailbox: mailbox, envelope: script.calls[2].body)
        XCTAssertEqual(next.publicationID, 50_000_001)
    }

    func testRelayQueueAndCacheControl() throws {
        let token = InteractionRelayCrypto.b64URLEncode(Data(repeating: 0x11, count: 32))
        let device = String(repeating: "33", count: 32)
        let mailbox = "vp_A1b2C3d4E5f6G7h8"
        var audits: [String] = []
        let script = ScriptRelay { request in
            if request.method == "DELETE" {
                return RelayHTTPResponse(status: 500, headers: [("Cache-Control", "no-store")], body: Data())
            }
            if request.method == "GET" {
                return RelayHTTPResponse(status: 204, headers: [("Cache-Control", "no-store")], body: Data())
            }
            return RelayHTTPResponse(status: 201, headers: [("Cache-Control", "no-store")], body: Data())
        }
        let relay = try InteractionRelay(
            store: MemoryRelayStore(), baseURL: "https://relay.example", mailbox: mailbox,
            macToken: token, deviceKeyHex: device, transport: { try script.send($0) },
            now: { 2_000 }, randomBytes: { Data(repeating: 0x5A, count: $0) }, jitter: { 0 },
            audit: { event, _ in audits.append(event) }
        )
        for byte in UInt8(1)...UInt8(8) { relay.onPark(makeJob(idByte: byte)) }
        XCTAssertEqual(relay.publishQueueSize, 8)
        relay.onPark(makeJob(idByte: 9))
        XCTAssertEqual(relay.publishQueueSize, 8)
        XCTAssertEqual(audits.last, "queue_full")
        relay.onRemove(requestID: makeJob(idByte: 1).requestID, reason: "abandoned")
        XCTAssertEqual(relay.publishQueueSize, 8)
        relay.runOnce()
        XCTAssertEqual(script.calls.filter { $0.method == "DELETE" }.map(\.url).count, 1)
        XCTAssertTrue(script.calls.contains { $0.method == "DELETE" && $0.url.hasSuffix(makeJob(idByte: 1).requestID) })
        XCTAssertEqual(script.calls.filter { $0.method == "PUT" }.count, 7)

        let blocked = ScriptRelay { _ in
            RelayHTTPResponse(status: 201, headers: [("Cache-Control", "private")], body: Data())
        }
        var blockedAudits: [String] = []
        let caching = try InteractionRelay(
            store: MemoryRelayStore(), baseURL: "https://relay.example", mailbox: mailbox,
            macToken: token, deviceKeyHex: device, transport: { try blocked.send($0) },
            now: { 3_000 }, randomBytes: { Data(repeating: 0x5A, count: $0) }, jitter: { 0 },
            audit: { event, _ in blockedAudits.append(event) }
        )
        caching.onPark(makeJob(idByte: 4))
        caching.runOnce()
        XCTAssertEqual(blocked.calls.map(\.method), ["PUT"])
        XCTAssertEqual(blockedAudits, ["failed"])
    }

    func testGitHubTokenSourceReadsEnvironmentThenFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-github-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let emptyHome = root.appendingPathComponent("empty-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)

        XCTAssertNil(GitHubTokenSource.token(environment: [:], homeDirectory: home, repoRoot: repo))
        XCTAssertNil(GitHubTokenSource.token(
            environment: ["GH_TOKEN": "  ", "GITHUB_TOKEN": "", "TG_GITHUB_TOKEN": "\n"],
            homeDirectory: home, repoRoot: repo))

        try " from-home \n".write(to: home.appendingPathComponent(".torget-github-token"), atomically: true, encoding: .utf8)
        try "from-repo\n".write(to: repo.appendingPathComponent(".github-token"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            GitHubTokenSource.token(environment: [:], homeDirectory: home, repoRoot: repo),
            "from-home")
        XCTAssertEqual(
            GitHubTokenSource.token(environment: ["GITHUB_TOKEN": " from-env "], homeDirectory: home, repoRoot: repo),
            "from-env")
        XCTAssertEqual(
            GitHubTokenSource.token(
                environment: ["GH_TOKEN": "gh", "GITHUB_TOKEN": "hub", "TG_GITHUB_TOKEN": "tg"],
                homeDirectory: home, repoRoot: repo),
            "gh")
        XCTAssertEqual(
            GitHubTokenSource.token(
                environment: ["GH_TOKEN": " ", "GITHUB_TOKEN": "hub"],
                homeDirectory: home, repoRoot: repo),
            "hub")
        XCTAssertEqual(
            GitHubTokenSource.token(
                environment: ["TG_GITHUB_TOKEN": " tg-env "],
                homeDirectory: emptyHome, repoRoot: repo),
            "tg-env")
        XCTAssertEqual(
            GitHubTokenSource.token(environment: [:], homeDirectory: emptyHome, repoRoot: repo),
            "from-repo")

        let bare = root.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        let header = """
        #define TG_OTA_TOKEN "not-this"
        # define TG_GITHUB_TOKEN "  header-token  "
        #define TG_GITHUB_TOKEN "second"
        """
        try header.write(to: bare.appendingPathComponent("secrets.h"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            GitHubTokenSource.token(environment: [:], homeDirectory: emptyHome, repoRoot: bare),
            "header-token")

        var broken = Data(#"#define TG_GITHUB_TOKEN "ab"#.utf8)
        broken.append(0xFF)
        broken.append(contentsOf: #"cd""#.utf8)
        try broken.write(to: bare.appendingPathComponent("secrets.h"))
        XCTAssertEqual(
            GitHubTokenSource.token(environment: [:], homeDirectory: emptyHome, repoRoot: bare),
            "abcd")

        try Data("not-a-define".utf8).write(to: bare.appendingPathComponent("secrets.h"))
        XCTAssertNil(GitHubTokenSource.token(environment: [:], homeDirectory: emptyHome, repoRoot: bare))
        try #"#define TG_GITHUB_TOKEN "   ""#.write(to: bare.appendingPathComponent("secrets.h"), atomically: true, encoding: .utf8)
        XCTAssertNil(GitHubTokenSource.token(environment: [:], homeDirectory: emptyHome, repoRoot: bare))

        var invalidHome = Data([0xFF, 0xFE])
        invalidHome.append(contentsOf: Data("nope".utf8))
        try invalidHome.write(to: home.appendingPathComponent(".torget-github-token"))
        XCTAssertEqual(
            GitHubTokenSource.token(environment: [:], homeDirectory: home, repoRoot: repo),
            "from-repo")
    }

    func testRelayURLSessionTransportRefusesRedirects() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedRelayURLProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let transport = RelayURLSessionTransport(configuration: configuration)
        let url = "https://relay.test/v1/mailboxes/box/status"
        ScriptedRelayState.shared.reset(
            status: 200,
            body: Data("pong".utf8),
            headers: ["Cache-Control": "no-store"])
        let response = try transport.send(relayRequest(url: url, method: "PUT", body: Data("{}".utf8)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("pong".utf8))
        XCTAssertTrue(response.headers.contains {
            $0.0.caseInsensitiveCompare("Cache-Control") == .orderedSame && $0.1 == "no-store"
        })
        let seen = ScriptedRelayState.shared.seen
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].method, "PUT")
        XCTAssertEqual(seen[0].authorization, "Bearer relay-secret")
        XCTAssertEqual(seen[0].accept, "application/json")
        XCTAssertEqual(seen[0].body, Data("{}".utf8))
        XCTAssertTrue(seen[0].url?.contains("relay.test") == true)
        XCTAssertFalse(seen.contains { $0.url?.contains("api.github.com") == true })

        ScriptedRelayState.shared.reset(
            status: 200,
            body: Data(count: InteractionRelayLimits.maxResponseBytes),
            headers: ["Cache-Control": "no-store"])
        let capped = try transport.send(relayRequest(url: url))
        XCTAssertEqual(capped.body.count, InteractionRelayLimits.maxResponseBytes)

        ScriptedRelayState.shared.reset(
            status: 200,
            body: Data(count: InteractionRelayLimits.maxResponseBytes + 1),
            headers: ["Cache-Control": "no-store"])
        XCTAssertThrowsError(try transport.send(relayRequest(url: url))) { error in
            XCTAssertEqual(error as? RelayAdapterError, RelayAdapterError(message: "relay response too large"))
            XCTAssertFalse(String(describing: error).contains("relay-secret"))
        }

        ScriptedRelayState.shared.reset(
            status: 302,
            body: Data("go-away".utf8),
            headers: ["Location": "https://evil.test/collect", "Cache-Control": "no-store"])
        XCTAssertThrowsError(try transport.send(relayRequest(url: url, method: "PUT", body: Data("{}".utf8)))) { error in
            XCTAssertEqual(error as? RelayAdapterError, RelayAdapterError(message: "relay redirect refused"))
            XCTAssertFalse(String(describing: error).contains("relay-secret"))
            XCTAssertFalse(String(describing: error).contains("evil.test"))
        }
        let redirected = ScriptedRelayState.shared.seen
        XCTAssertEqual(redirected.count, 1)
        XCTAssertTrue(redirected[0].url?.contains("relay.test") == true)
        XCTAssertFalse(redirected.contains { $0.url?.contains("evil.test") == true })
        XCTAssertFalse(redirected.contains { $0.url?.contains("api.github.com") == true })

        ScriptedRelayState.shared.reset(status: 200, body: Data(), headers: [:])
        for sample in [
            "http://relay.test/path",
            "https://user:secret@relay.test/path",
            "https://relay.test/path?x=1",
            "https://relay.test/path#frag",
        ] {
            XCTAssertThrowsError(try transport.send(relayRequest(url: sample))) { error in
                XCTAssertEqual(error as? RelayAdapterError, RelayAdapterError(message: "invalid relay request URL"))
                XCTAssertFalse(String(describing: error).contains("secret"))
            }
        }
        XCTAssertTrue(ScriptedRelayState.shared.seen.isEmpty)
    }

    private func relayRequest(url: String, method: String = "GET", body: Data = Data()) -> RelayHTTPRequest {
        var headers = [("Accept", "application/json"), ("Authorization", "Bearer relay-secret")]
        if !body.isEmpty { headers.append(("Content-Type", "application/json")) }
        return RelayHTTPRequest(
            method: method, url: url, headers: headers, body: body, connectTimeout: 1, readTimeout: 2)
    }

    private func makeJob(idByte: UInt8) -> RelayPublishJob {
        let view = Data("{\"provider\":\"codex\"}".utf8)
        return RelayPublishJob(
            requestID: InteractionRelayCrypto.b64URLEncode(Data(repeating: idByte, count: 16)),
            challenge: Data(repeating: idByte, count: 32),
            viewBytes: view,
            viewSHA256: Data(SHA256.hash(data: view)),
            expiresAt: 1_700_000_000,
            provider: "codex",
            canApprove: true
        )
    }

    private func repoJSON(stars: Int, forks: Int) -> GitHubHTTPResponse {
        let raw = #"{"private":false,"stargazers_count":\#(stars),"forks_count":\#(forks),"name":"vibepulse"}"#
        return GitHubHTTPResponse(status: 200, body: Data(raw.utf8))
    }

    private func loadVector(named name: String = "interaction-relay-v1.json") throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("test-vectors/\(name)")
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

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private final class PublisherPayloads {
    var tokens: CanonicalJSON.Value = .object([
        "usageTotals": .object(["placeholder": .bool(true)]),
        "claudeWeekStale": .bool(true),
    ])
    var github: CanonicalJSON.Value = .object(["v": .int(1), "stars": .int(1)])
}

private final class ScriptRelay {
    var calls: [RelayHTTPRequest] = []
    var handler: (RelayHTTPRequest) throws -> RelayHTTPResponse
    init(_ handler: @escaping (RelayHTTPRequest) throws -> RelayHTTPResponse) { self.handler = handler }
    func send(_ request: RelayHTTPRequest) throws -> RelayHTTPResponse {
        calls.append(request)
        return try handler(request)
    }
}

private final class MemoryRelayStore: RelayResolving {
    weak var listener: InteractionRelay?
    var job: RelayPublishJob?
    var accepted = false
    func setRelayListener(_ listener: InteractionRelay?) { self.listener = listener }
    func resolve(
        _ result: RelayResolution,
        verify: (RelayPublishJob, RelayResolution) -> Bool
    ) -> (accepted: Bool, reason: String) {
        guard let job else { return (false, "no such pending interaction") }
        let ok = verify(job, result)
        accepted = ok
        return (ok, ok ? "ok" : "signature rejected")
    }
}

private final class GitHubScript {
    struct Call {
        var url: String
        var headers: [String: String]
    }
    var calls: [Call] = []
    var responses: [GitHubHTTPResponse] = []
    func fetch(_ request: GitHubHTTPRequest) throws -> GitHubHTTPResponse {
        calls.append(Call(url: request.url, headers: request.headers))
        return responses.removeFirst()
    }
}

private struct DiscoveryBoom: Error {}

private final class RecordingRegistrar: DiscoveryRegistering {
    var advertisements: [DiscoveryAdvertisement] = []
    var stopped = 0
    var failure: Error?
    func register(_ advertisement: DiscoveryAdvertisement) throws {
        if let failure { throw failure }
        advertisements.append(advertisement)
    }
    func unregister() { stopped += 1 }
}

private struct CapturedRelayLoad: Equatable {
    var method: String?
    var url: String?
    var authorization: String?
    var accept: String?
    var body: Data
}

private final class ScriptedRelayState: @unchecked Sendable {
    static let shared = ScriptedRelayState()
    private let lock = NSLock()
    private var status = 200
    private var body = Data()
    private var headers: [String: String] = [:]
    private var loads: [CapturedRelayLoad] = []

    func reset(status: Int, body: Data, headers: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
        self.body = body
        self.headers = headers
        loads = []
    }

    func record(_ request: URLRequest, body: Data) -> (Int, Data, [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        loads.append(CapturedRelayLoad(
            method: request.httpMethod,
            url: request.url?.absoluteString,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            accept: request.value(forHTTPHeaderField: "Accept"),
            body: body))
        return (status, self.body, headers)
    }

    var seen: [CapturedRelayLoad] {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }
}

private final class ScriptedRelayURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body, headers) = ScriptedRelayState.shared.record(request, body: Self.readBody(request))
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let address = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return stream.read(address, maxLength: raw.count)
            }
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
