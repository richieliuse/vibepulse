import AppKit
import VibePulseBarCore

struct StatusIconState: Equatable {
    enum Mark: Equatable {
        case none
        /// An agent is waiting for the user.
        case attention
        /// The service crashed, stopped answering, or cannot start.
        case problem
    }

    /// 0...1 fills; `nil` draws the empty track only.
    var top: Double?
    var bottom: Double?
    var paused: Bool
    var mark: Mark

    static func make(from snapshot: DashboardSnapshot, iconProvider: Provider?) -> StatusIconState {
        let service = snapshot.service
        let usage = iconProvider.map(snapshot.usage)
            ?? Provider.allCases.map(snapshot.usage).max { lhs, rhs in
                (lhs.mostConstrained?.usedPercent ?? -1) < (rhs.mostConstrained?.usedPercent ?? -1)
            }
        func fraction(_ metric: QuotaMetric?) -> Double? {
            guard let used = metric?.usedPercent else { return nil }
            return (snapshot.usageDisplay == .used ? used : 100 - used) / 100
        }
        let mark: Mark
        switch service.tone {
        case .failure, .warning: mark = .problem
        default: mark = (snapshot.agents?.totalWaiting ?? 0) > 0 ? .attention : .none
        }
        let primary = usage?.primary
        let secondary = usage?.session ?? usage?.metrics.first { $0.id != primary?.id }
        return StatusIconState(
            top: fraction(secondary),
            bottom: fraction(primary),
            paused: service.phase == .idle,
            mark: mark)
    }
}

enum StatusIconRenderer {
    static func image(for state: StatusIconState) -> NSImage {
        let size = NSSize(width: state.mark == .none ? 18 : 22, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            self.draw(state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "VibePulse"
        return image
    }

    private static func draw(_ state: StatusIconState) {
        let alpha: CGFloat = state.paused ? 0.45 : 1
        NSColor.black.withAlphaComponent(alpha).setStroke()
        let barX: CGFloat = 1.5
        let barWidth: CGFloat = 15
        self.bar(y: 9, height: 4.5, x: barX, width: barWidth, fraction: state.paused ? nil : state.top,
                 alpha: alpha)
        self.bar(y: 2.5, height: 4.5, x: barX, width: barWidth, fraction: state.paused ? nil : state.bottom,
                 alpha: alpha)
        switch state.mark {
        case .none:
            break
        case .attention:
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 17.5, y: 9.5, width: 4.5, height: 4.5)).fill()
        case .problem:
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 18.6, y: 6, width: 2, height: 8.5), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(ovalIn: NSRect(x: 18.5, y: 1.5, width: 2.2, height: 2.2)).fill()
        }
    }

    private static func bar(y: CGFloat, height: CGFloat, x: CGFloat, width: CGFloat, fraction: Double?,
                            alpha: CGFloat) {
        let track = NSRect(x: x, y: y, width: width, height: height)
        let radius = height / 2
        let outline = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        outline.lineWidth = 1
        outline.stroke()
        guard let fraction else { return }
        let clamped = CGFloat(min(1, max(0, fraction)))
        guard clamped > 0 else { return }
        let fillWidth = max(height, width * clamped)
        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fillWidth, height: height),
                     xRadius: radius, yRadius: radius).fill()
    }
}
