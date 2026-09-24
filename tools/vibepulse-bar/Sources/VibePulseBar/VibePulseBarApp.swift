import AppKit
import SwiftUI
import VibePulseBarCore

@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--render-previews"), arguments.count > flag + 2 {
            do {
                try PreviewRenderer.run(outputDirectory: URL(fileURLWithPath: arguments[flag + 1]),
                                        fixtures: URL(fileURLWithPath: arguments[flag + 2]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        VibePulseBarApp.main()
    }
}

struct VibePulseBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: self.appDelegate.model)
        }
    }
}

struct MenuBarRoot: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        LiveMenuView(model: self.model, actions: self.actions)
    }

    private var actions: ServiceActions {
        let model = self.model
        let openSettings = self.openSettings
        return ServiceActions(
            start: model.startService,
            pause: model.pauseService,
            restart: model.restartService,
            takeOverExternal: model.takeOverExternal,
            takeOverLaunchAgent: model.takeOverLaunchAgent,
            openLog: {
                MenuWindow.dismiss()
                model.openLog()
            },
            openDiagnostics: {
                MenuWindow.dismiss()
                model.openDiagnostics()
            },
            openSettings: {
                // An accessory policy cannot present the Settings scene. Promote
                // first, then send the scene action. Tab clicks must not reach
                // this: those rows no longer carry `.keyboardShortcut`.
                MenuWindow.dismiss()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                openSettings()
            },
            about: {
                MenuWindow.dismiss()
                NSApp.activate()
                NSApp.orderFrontStandardAboutPanel(nil)
            },
            quit: { NSApp.terminate(nil) })
    }
}

@MainActor
enum MenuWindow {
    static func dismiss() {
        MenuStatusController.shared?.hide()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var shutdownFinished = false
    private var shutdownStarted = false
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One engine per session: a second copy would see this process's port as busy.
        if let running = Self.otherInstance() {
            running.activate()
            self.shutdownFinished = true
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        self.installSignalHandlers()
        self.model.bootstrap()
        MenuStatusController.install(model: self.model)
    }

    private static func otherInstance() -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// Quit waits for the in-process engine to stop, so the Max Tracker flush
    /// and relay stop still run. There is no child process to reap.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if self.shutdownFinished { return .terminateNow }
        guard !self.shutdownStarted else { return .terminateLater }
        self.shutdownStarted = true
        Task { @MainActor in
            await self.model.shutdown()
            self.shutdownFinished = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// `kill <pid>` or Ctrl-C from `swift run` still stops the service first.
    ///
    /// The handler runs as a main-queue callout, where `.terminateLater`
    /// would deadlock: AppKit's wait loop cannot drain the main queue that
    /// the shutdown task is queued on. So this path finishes the shutdown
    /// before asking AppKit to terminate.
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, !self.shutdownStarted else { return }
                    self.shutdownStarted = true
                    await self.model.shutdown()
                    self.shutdownFinished = true
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            self.signalSources.append(source)
        }
    }
}
