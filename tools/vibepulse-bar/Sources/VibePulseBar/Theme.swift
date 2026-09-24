import SwiftUI
import VibePulseBarCore

enum MenuTab: Hashable, Codable {
    case overview
    case provider(Provider)

    static let all: [MenuTab] = [.overview] + Provider.allCases.map(MenuTab.provider)

    var title: String {
        switch self {
        case .overview: "Overview"
        case let .provider(provider): provider.displayName
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case let .provider(provider): provider.symbol
        }
    }
}

enum UsageDisplay: String, Codable, CaseIterable, Identifiable {
    case used
    case remaining

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .used: "Used"
        case .remaining: "Remaining"
        }
    }
}

extension Provider {
    /// Neutral symbols: the provider marks belong to their owners.
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "bolt.fill"
        case .cursor: "cursorarrow.rays"
        }
    }

    /// The panel's locked accents for Claude and Codex; Grok and Cursor are
    /// monochrome on the panel, so they follow the system label colour here.
    var accent: Color {
        switch self {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex: Color(red: 0x6F / 255, green: 0x78 / 255, blue: 0xFF / 255)
        case .grok: Color.primary.opacity(0.75)
        case .cursor: Color.primary.opacity(0.6)
        }
    }
}

extension ServiceSnapshot.Tone {
    var color: Color {
        switch self {
        case .healthy: .green
        case .pending: .yellow
        case .paused: .secondary
        case .warning: .orange
        case .failure: .red
        }
    }
}

extension AgentState {
    var color: Color {
        switch self {
        case .waiting: .orange
        case .error: .red
        case .working: .green
        case .done: .secondary
        case .idle, .unknown: Color.secondary.opacity(0.6)
        }
    }

    var label: String {
        switch self {
        case .waiting: "Needs you"
        case .error: "Error"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }
}

enum MenuMetrics {
    static let width: CGFloat = 320
    static let cardPadding: CGFloat = 14
    static let rowInset: CGFloat = 5
}
