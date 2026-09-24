import Foundation

/// DNS-SD service type from `discovery.py`: `_vibepulse._tcp.local.`
/// Bonjour regtype is `_vibepulse._tcp` in domain `local.`. TXT is exactly `v=1`.
/// This slice does not call `DNSServiceRegister`. A `DiscoveryRegistering` stands in for zeroconf.
public enum DiscoveryService {
    public static let serviceType = "_vibepulse._tcp.local."
    public static let bonjourRegtype = "_vibepulse._tcp"
    public static let protocolVersion = "1"
}

public struct IPv4Address: Equatable, Sendable {
    public var a: UInt8
    public var b: UInt8
    public var c: UInt8
    public var d: UInt8

    public var dotted: String { "\(a).\(b).\(c).\(d)" }
    public var packed: Data { Data([a, b, c, d]) }

    public init(a: UInt8, b: UInt8, c: UInt8, d: UInt8) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    public static func parse(_ text: String) -> IPv4Address? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count),
                  part.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
                  !(part.count > 1 && part.first == "0"),
                  let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(UInt8(value))
        }
        return IPv4Address(a: octets[0], b: octets[1], c: octets[2], d: octets[3])
    }

    public var isRoutableLAN: Bool {
        if a == 127 { return false }
        if a == 169 && b == 254 { return false }
        if a == 0 && b == 0 && c == 0 && d == 0 { return false }
        return true
    }
}

/// Drops loopback, link-local, and unspecified addresses, then sorts by dotted string.
public func routableIPv4Addresses(_ dotted: [String]) -> [Data] {
    var seen = Set<String>()
    var addresses: [IPv4Address] = []
    for text in dotted {
        guard let address = IPv4Address.parse(text), address.isRoutableLAN, seen.insert(address.dotted).inserted else {
            continue
        }
        addresses.append(address)
    }
    addresses.sort { $0.dotted < $1.dotted }
    return addresses.map(\.packed)
}

/// ASCII alphanumerics stay (lowercased). Everything else becomes `-`, runs collapse, empty is `host`, max 48.
public func safeDNSLabel(_ value: String) -> String {
    var label = ""
    for scalar in value.unicodeScalars {
        if (0x30...0x39).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
            label.unicodeScalars.append(scalar)
        } else if (0x41...0x5A).contains(scalar.value) {
            label.unicodeScalars.append(UnicodeScalar(scalar.value + 32)!)
        } else {
            label.append("-")
        }
    }
    while label.hasPrefix("-") { label.removeFirst() }
    while label.hasSuffix("-") { label.removeLast() }
    while label.contains("--") {
        label = label.replacingOccurrences(of: "--", with: "-")
    }
    if label.isEmpty { label = "host" }
    if label.count > 48 { label = String(label.prefix(48)) }
    return label
}

public struct DiscoveryAdvertisement: Equatable, Sendable {
    public var serviceType: String
    public var instanceName: String
    public var serverName: String
    public var port: Int
    public var addresses: [Data]
    public var text: [String: String]

    public init(serviceType: String, instanceName: String, serverName: String, port: Int,
                addresses: [Data], text: [String: String]) {
        self.serviceType = serviceType
        self.instanceName = instanceName
        self.serverName = serverName
        self.port = port
        self.addresses = addresses
        self.text = text
    }
}

public protocol DiscoveryRegistering: AnyObject {
    func register(_ advertisement: DiscoveryAdvertisement) throws
    func unregister()
}

public final class DiscoveryAdvertiser {
    public private(set) var status = "off"
    public private(set) var reason: String?
    private let addresses: () -> [String]
    private let hostname: () -> String
    private let registrar: DiscoveryRegistering?
    private var registered = false

    public init(
        addresses: @escaping () -> [String] = { [] },
        hostname: @escaping () -> String = { ProcessInfo.processInfo.hostName },
        registrar: DiscoveryRegistering? = nil
    ) {
        self.addresses = addresses
        self.hostname = hostname
        self.registrar = registrar
    }

    public func start(port: Int) -> Bool {
        guard (1...65535).contains(port) else {
            status = "error"
            reason = "invalid-port"
            return false
        }
        guard let registrar else {
            status = "unavailable"
            reason = "dependency-missing"
            return false
        }
        let packed = routableIPv4Addresses(addresses())
        guard !packed.isEmpty else {
            status = "unavailable"
            reason = "no-lan-address"
            return false
        }
        let label = safeDNSLabel(hostname())
        let advertisement = DiscoveryAdvertisement(
            serviceType: DiscoveryService.serviceType,
            instanceName: "VibePulse-\(label).\(DiscoveryService.serviceType)",
            serverName: "vibepulse-\(label).local.",
            port: port,
            addresses: packed,
            text: ["v": DiscoveryService.protocolVersion]
        )
        do {
            try registrar.register(advertisement)
        } catch {
            status = "error"
            reason = String(describing: type(of: error))
            return false
        }
        registered = true
        status = "ready"
        reason = nil
        return true
    }

    /// Unregisters once after a successful `start` when a registrar was injected.
    /// A second call, or a call before that, does nothing.
    public func stop() {
        guard registered, let registrar else { return }
        registered = false
        registrar.unregister()
    }
}
