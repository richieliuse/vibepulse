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
        MenuBarExtra {
            MenuBarRoot(model: self.appDelegate.model)
        } label: {
            StatusItemLabel(model: self.appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: self.appDelegate.model)
        }
    }
}

private struct StatusItemLabel: View {
    let model: AppModel

    var body: some View {
        let state = StatusIconState.make(from: self.model.snapshot(),
                                         iconProvider: self.model.preferences.iconProvider)
        Image(nsImage: StatusIconRenderer.image(for: state))
    }
}

private struct MenuBarRoot: View {
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
                MenuWindow.dismiss()
                NSApp.activate()
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
    /// `MenuBarExtra` has no dismiss API; closing its panel is the supported
    /// way to hand focus to the window an action opens.
    static func dismiss() {
        for window in NSApp.windows where String(describing: type(of: window)).contains("MenuBarExtra") {
            window.close()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var shutdownFinished = false
    private var shutdownStarted = false
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One supervisor per session: a second copy would count the first
        // one's server as foreign and offer to take it over.
        if let running = Self.otherInstance() {
            running.activate()
            self.shutdownFinished = true
            NSApp.terminate(nil)
            return
        }
        self.installSignalHandlers()
        self.model.bootstrap()
    }

    private static func otherInstance() -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// Quit waits for the owned tokenserver to finish its SIGINT cleanup, so
    /// the Max Tracker flush and relay stop still run.
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
