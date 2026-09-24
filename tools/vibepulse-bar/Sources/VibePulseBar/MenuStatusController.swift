import AppKit
import Observation
import SwiftUI

/// Status item and panel. `MenuBarExtra`'s window keeps its old height when a
/// tab changes, so the rows slide down and clip. This panel measures the
/// SwiftUI view and grows downward from a fixed top edge.
@MainActor
final class MenuStatusController: NSObject {
    static private(set) var shared: MenuStatusController?

    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: NSPanel
    private let hosting: NSHostingView<MenuHost>
    private var monitors: [Any] = []
    private var iconWatch: Task<Void, Never>?

    static func install(model: AppModel) {
        shared = MenuStatusController(model: model)
    }

    private init(model: AppModel) {
        self.model = model
        let hosting = NSHostingView(rootView: MenuHost(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        self.hosting = hosting
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 240),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        self.panel = panel
        super.init()
        let button = self.statusItem.button
        button?.imagePosition = .imageOnly
        button?.target = self
        button?.action = #selector(self.toggle)
        self.refreshIcon()
        self.watchIcon()
        self.relayout()
    }

    func hide() {
        self.panel.orderOut(nil)
        self.statusItem.button?.highlight(false)
        self.removeMonitors()
    }

    @objc private func toggle() {
        if self.panel.isVisible {
            self.hide()
        } else {
            self.show()
        }
    }

    private func show() {
        self.relayout()
        self.placeUnderStatusItem()
        self.panel.makeKeyAndOrderFront(nil)
        self.statusItem.button?.highlight(true)
        self.installMonitors()
    }

    /// Size once, before the panel is shown. A tab click must not change the
    /// frame: AppKit does not support resizing a menu while it is tracking,
    /// and doing it here moves the panel because each page has its own height.
    fileprivate func relayout() {
        guard !self.panel.isVisible else { return }
        self.hosting.layoutSubtreeIfNeeded()
        let fitted = self.hosting.fittingSize
        guard fitted.width > 1, fitted.height > 1, fitted.height < 2000 else { return }
        self.panel.setContentSize(fitted)
    }

    private func placeUnderStatusItem() {
        guard let button = self.statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = self.panel.frame.size
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 2)
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = max(origin.y, visible.minY + 4)
        }
        self.panel.setFrameOrigin(origin)
    }

    private func installMonitors() {
        self.removeMonitors()
        let mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hideIfClickIsOutside() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.hide()
                return nil
            }
            if event.type != .keyDown {
                let point = NSEvent.mouseLocation
                if !self.panel.frame.contains(point) { self.hide() }
            }
            return event
        }
        self.monitors = [mouse, local].compactMap { $0 }
    }

    private func hideIfClickIsOutside() {
        guard self.panel.isVisible else { return }
        if !self.panel.frame.contains(NSEvent.mouseLocation) { self.hide() }
    }

    private func removeMonitors() {
        for monitor in self.monitors { NSEvent.removeMonitor(monitor) }
        self.monitors.removeAll()
    }

    private func refreshIcon() {
        let state = StatusIconState.make(from: self.model.snapshot(),
                                         iconProvider: self.model.preferences.iconProvider)
        self.statusItem.button?.image = StatusIconRenderer.image(for: state)
    }

    private func watchIcon() {
        self.iconWatch?.cancel()
        withObservationTracking {
            _ = self.model.snapshot()
            _ = self.model.preferences.iconProvider
        } onChange: {
            Task { @MainActor in
                self.refreshIcon()
                self.watchIcon()
            }
        }
    }
}

/// Hosts the menu and reports a new fitting size after each tab change.
private struct MenuHost: View {
    let model: AppModel

    var body: some View {
        MenuBarRoot(model: self.model)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(MenuSizeBridge())
    }
}

private struct MenuSizeBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            MenuStatusController.shared?.relayout()
        }
    }
}
