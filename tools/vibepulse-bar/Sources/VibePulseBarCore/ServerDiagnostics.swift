import Foundation

public enum Provider: String, CaseIterable, Sendable, Identifiable, Codable {
    case claude
    case codex
    case grok
    case cursor

    public var id: String { self.rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .cursor: "Cursor"
        }
    }

    /// Only these two have a live session monitor in the service.
    public var hasAgentMonitor: Bool { self == .claude || self == .codex }
}

/// One upstream probe as reported on `GET /`.
public struct ProbeStatus: Sendable, Equatable {
    public var status: String?
    public var ageSeconds: Int?
    public var intervalSeconds: Int?
    public var cooldownLeftSeconds: Int?

    public var isHealthy: Bool {
        guard let status else { return false }
        return status == "ok" || status.hasSuffix("+ ok")
    }
}

public struct PanelHealth: Sendable, Equatable {
    /// `ready`, `stale` or `waiting` (never seen).
    public var status: String
    public var ageSeconds: Int?
}

/// The subset of `GET /` the app shows. The screen never parses this route,
/// so the service may add fields freely; everything here is optional.
public struct ServerDiagnostics: Sendable, Equatable {
    public var service: String?
    public var rev: String?
    public var sourceFingerprint: String?
    public var startedAt: Date?
    public var probes: [Provider: ProbeStatus]
    public var claudeCredentialStatus: String?
    public var usageComputeOK: Bool?
    public var usageTotals: UsageTotalsState?
    public var discoveryStatus: String?
    public var panel: PanelHealth?

    public static let serviceName = "torget-tokenserver"

    public var isTokenServer: Bool { self.service == Self.serviceName }

    public init?(data: Data) {
        guard let json = JSONReader(data: data) else { return nil }
        self.service = json.string("service")
        self.rev = json.string("rev")
        self.sourceFingerprint = json.string("srcFingerprint")
        self.startedAt = json.string("startedAt").flatMap(Self.parseDate)
        var probes: [Provider: ProbeStatus] = [:]
        for provider in Provider.allCases {
            let prefix = provider.rawValue + "Probe"
            guard json.object[prefix] != nil else { continue }
            probes[provider] = ProbeStatus(
                status: json.string(prefix),
                ageSeconds: json.int(prefix + "AgeS"),
                intervalSeconds: json.int(prefix + "IntervalS"),
                cooldownLeftSeconds: json.int(prefix + "CooldownLeftS"))
        }
        self.probes = probes
        self.claudeCredentialStatus = json.reader("claudeCredential")?.string("status")
        self.usageComputeOK = json.bool("usageComputeOk")
        self.usageTotals = json.reader("usageTotals").map { totals in
            UsageTotalsState(
                state: totals.string("state"),
                placeholder: totals.bool("placeholder") ?? false,
                ageSeconds: totals.int("ageS") ?? totals.int("sinceS"))
        }
        self.discoveryStatus = json.reader("discovery")?.string("status")
        self.panel = json.reader("interactions")?.reader("panel").flatMap { panel in
            panel.string("status").map { PanelHealth(status: $0, ageSeconds: panel.int("ageS")) }
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
