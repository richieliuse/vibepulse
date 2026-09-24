import AppKit
import SwiftUI
import VibePulseBarCore

/// `VibePulseBar --render-previews <out-dir> <fixtures-dir>` writes the menu
/// in fixed states as PNGs, for the README and for reviewing layout without
/// clicking through a live menu.
@MainActor
enum PreviewRenderer {
    struct Scenario {
        var name: String
        var tab: MenuTab
        var snapshot: DashboardSnapshot
    }

    static func run(outputDirectory: URL, fixtures: URL) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_790_190_000)
        for scenario in try self.scenarios(fixtures: fixtures, now: now) {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                let url = outputDirectory.appendingPathComponent("\(scenario.name)-\(suffix).png")
                try self.write(self.menu(scenario, now: now, scheme: scheme), to: url)
                print(url.path)
            }
        }
        try self.writeIcons(to: outputDirectory)
    }

    static func scenarios(fixtures: URL, now: Date) throws -> [Scenario] {
        func load(_ name: String) throws -> Data {
            try Data(contentsOf: fixtures.appendingPathComponent(name))
        }
        let tokens = TokensSnapshot(data: try load("tokens-full.json"))
        let agents = AgentStatusSnapshot(data: try load("agent-status.json"))
        let diagnostics = ServerDiagnostics(data: try self.healthyClaude(load("diagnostics.json")))
        let running = ServiceSnapshot(
            phase: .running, pid: 48213, processStartedAt: now.addingTimeInterval(-3 * 3600 - 17 * 60),
            diagnostics: diagnostics, ownsProcess: true, wantsRunning: true, isServing: true)
        let live = DashboardSnapshot(
            service: running, tokens: tokens, tokensFetchedAt: now.addingTimeInterval(-8), tokensStale: false,
            agents: agents, agentsFetchedAt: now.addingTimeInterval(-1), usageDisplay: .used)

        var paused = live
        paused.service = ServiceSnapshot(phase: .idle)
        paused.tokensFetchedAt = now.addingTimeInterval(-345)
        paused.tokensStale = true
        paused.agents = nil

        var crashed = paused
        crashed.service = ServiceSnapshot(
            phase: .failed,
            lastError: "The server did not start.",
            wantsRunning: true)
        crashed.tokens = nil
        crashed.agents = nil

        var external = live
        external.service = ServiceSnapshot(
            phase: .external,
            foreign: ProcessDescription(
                pid: 4242, command: "tokenserver",
                startTime: nil),
            isServing: false)
        external.tokens = nil
        external.agents = nil

        var remaining = live
        remaining.usageDisplay = .remaining

        return [
            Scenario(name: "overview", tab: .overview, snapshot: live),
            Scenario(name: "claude", tab: .provider(.claude), snapshot: live),
            Scenario(name: "codex", tab: .provider(.codex), snapshot: live),
            Scenario(name: "grok", tab: .provider(.grok), snapshot: remaining),
            Scenario(name: "cursor", tab: .provider(.cursor), snapshot: remaining),
            Scenario(name: "overview-paused", tab: .overview, snapshot: paused),
            Scenario(name: "overview-crashed", tab: .overview, snapshot: crashed),
            Scenario(name: "overview-external", tab: .overview, snapshot: external),
        ]
    }

    /// The captured diagnostics come from a host without Claude credentials;
    /// the full tokens fixture has Claude data, so the probe must agree.
    private static func healthyClaude(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        object["claudeProbe"] = "usage_http_200 + ok"
        object["claudeProbeAgeS"] = 12
        object["claudeCredential"] = ["status": "ready"]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func menu(_ scenario: Scenario, now: Date, scheme: ColorScheme) -> some View {
        MenuContentView(snapshot: scenario.snapshot, selection: scenario.tab, now: now,
                        actions: ServiceActions(), onSelect: { _ in })
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.965)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .padding(10)
            .environment(\.colorScheme, scheme)
    }

    private static func write(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw RenderError.empty(url.lastPathComponent) }
        try self.png(image, to: url)
    }

    private static func writeIcons(to directory: URL) throws {
        let states: [(String, StatusIconState)] = [
            ("icon-running", .init(top: 0.42, bottom: 0.61, paused: false, mark: .none)),
            ("icon-attention", .init(top: 0.42, bottom: 0.61, paused: false, mark: .attention)),
            ("icon-problem", .init(top: nil, bottom: nil, paused: false, mark: .problem)),
            ("icon-paused", .init(top: 0.42, bottom: 0.61, paused: true, mark: .none)),
        ]
        for (name, state) in states {
            let icon = StatusIconRenderer.image(for: state)
            let scale: CGFloat = 8
            let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            icon.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            let url = directory.appendingPathComponent("\(name).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
    }

    private static func png(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.empty(url.lastPathComponent)
        }
        try data.write(to: url)
    }

    enum RenderError: Error {
        case empty(String)
    }
}
