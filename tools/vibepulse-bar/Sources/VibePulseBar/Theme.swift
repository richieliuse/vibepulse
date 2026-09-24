import AppKit
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
    /// Neutral symbols kept for accessibility labels. The drawn mark is
    /// `ProviderMark`, CodexBar's `ProviderIcon-<id>.svg`.
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "bolt.fill"
        case .cursor: "cursorarrow.rays"
        }
    }

    /// Hardware accents for Claude and Codex. Grok and Cursor bars are a dark
    /// green; their marks stay monochrome in the tab.
    var accent: Color {
        switch self {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex: Color(red: 0x6F / 255, green: 0x78 / 255, blue: 0xFF / 255)
        case .grok, .cursor: Color(red: 0x1B / 255, green: 0x6B / 255, blue: 0x3A / 255)
        }
    }
}

/// CodexBar's provider SVGs, drawn as template images so the tab tint applies.
@MainActor
enum ProviderMark {
    static func image(for provider: Provider) -> NSImage {
        let cached = cache[provider]
        if let cached { return cached }
        let loaded = load(provider) ?? NSImage(systemSymbolName: provider.symbol, accessibilityDescription: provider.displayName) ?? NSImage()
        loaded.isTemplate = true
        cache[provider] = loaded
        return loaded
    }

    private static var cache: [Provider: NSImage] = [:]

    private static func load(_ provider: Provider) -> NSImage? {
        let name = "ProviderIcon-\(provider.rawValue)"
        let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
        guard let url, let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        return image
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
