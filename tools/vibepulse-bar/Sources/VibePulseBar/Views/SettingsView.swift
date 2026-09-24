import AppKit
import SwiftUI
import VibePulseBarCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: self.model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ServiceSettings(model: self.model)
                .tabItem { Label("Service", systemImage: "server.rack") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560)
        .padding(.vertical, 4)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch VibePulse Bar at login", isOn: self.$launchAtLogin)
                    .onChange(of: self.launchAtLogin) { _, enabled in
                        guard enabled != self.model.launchesAtLogin else { return }
                        do {
                            try self.model.setLaunchesAtLogin(enabled)
                            self.loginError = nil
                        } catch {
                            self.loginError = error.localizedDescription
                            self.launchAtLogin = self.model.launchesAtLogin
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Start the tokenserver when the app opens",
                       isOn: self.$model.preferences.startServiceOnLaunch)
                Toggle("Restart the tokenserver after a crash",
                       isOn: self.$model.preferences.autoRestart)
                Text("Crash restarts back off from 5 s to 60 s, like the LaunchAgent's 30 s throttle; a run that lasted two minutes resets the ladder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Display") {
                Picker("Show quota as", selection: self.$model.preferences.usageDisplay) {
                    ForEach(UsageDisplay.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Menu bar icon follows", selection: self.$model.preferences.iconProvider) {
                    Text("Most used provider").tag(Provider?.none)
                    ForEach(Provider.allCases) { Text($0.displayName).tag(Provider?.some($0)) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { self.launchAtLogin = self.model.launchesAtLogin }
    }
}

private struct ServiceSettings: View {
    @Bindable var model: AppModel
    @State private var draft = ServiceConfiguration(pythonPath: "", scriptPath: "")
    @State private var argumentsText = ""
    @State private var portText = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    let service = self.model.supervisor.snapshot
                    HStack(spacing: 6) {
                        StatusDot(color: service.tone.color)
                        Text("\(service.headline) — \(service.detail(now: Date()))")
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Configuration", value: self.model.configurationSource.rawValue)
            }
            Section("Launch command") {
                PathField(title: "Python", path: self.$draft.pythonPath, chooseDirectories: false)
                PathField(title: "Server script", path: self.$draft.scriptPath, chooseDirectories: false)
                PathField(title: "Working directory", path: self.workingDirectory, chooseDirectories: true)
                TextField("Port", text: self.$portText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra arguments, one per line")
                    TextEditor(text: self.$argumentsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
                PathField(title: "Log file", path: self.$draft.logPath, chooseDirectories: false)
                ForEach(self.issues, id: \.message) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                HStack {
                    Button("Import from LaunchAgent") { self.importLaunchAgent() }
                    Button("Use This Checkout") { self.useCheckout() }
                    Spacer()
                    Button("Apply") { self.apply(restart: false) }
                    Button("Apply and Restart") { self.apply(restart: true) }
                        .keyboardShortcut(.defaultAction)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("LaunchAgent") {
                LaunchAgentSection(model: self.model)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: self.load)
    }

    private var workingDirectory: Binding<String> {
        Binding(
            get: { self.draft.workingDirectory ?? "" },
            set: { self.draft.workingDirectory = $0.isEmpty ? nil : $0 })
    }

    private var edited: ServiceConfiguration {
        var configuration = self.draft
        configuration.arguments = self.argumentsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        configuration.port = Int(self.portText.trimmingCharacters(in: .whitespaces))
            ?? ServiceConfiguration.defaultPort
        return configuration
    }

    private var issues: [ServiceConfiguration.Issue] { self.edited.validate() }

    private func load() {
        self.draft = self.model.configuration
        self.argumentsText = self.draft.arguments.joined(separator: "\n")
        self.portText = String(self.draft.port)
    }

    private func apply(restart: Bool) {
        self.model.configuration = self.edited
        self.load()
        self.message = "Saved."
        if restart {
            self.model.restartService()
            self.message = "Saved; restarting the service."
        }
    }

    private func importLaunchAgent() {
        do {
            try self.model.importLaunchAgent()
            self.load()
            self.message = "Imported \(ServiceConfiguration.launchAgentPath)."
        } catch {
            self.message = error.localizedDescription
        }
    }

    private func useCheckout() {
        if self.model.resetToRepositoryDefault() {
            self.load()
            self.message = "Using the checkout this app was built from."
        } else {
            self.message = "This app was not built inside a VibePulse checkout."
        }
    }
}

private struct LaunchAgentSection: View {
    @Bindable var model: AppModel

    var body: some View {
        let agent = self.model.supervisor.launchAgent
        let service = self.model.supervisor.snapshot
        VStack(alignment: .leading, spacing: 6) {
            Text(self.summary(agent))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if service.phase == .launchAgent {
                    Button("Take Over from launchd") { self.model.takeOverLaunchAgent() }
                }
                if agent.plistExists, !agent.loaded {
                    Button("Hand Back to launchd") { self.model.handBackToLaunchAgent() }
                }
            }
        }
    }

    private func summary(_ agent: LaunchAgentStatus) -> String {
        guard agent.plistExists else {
            return "No LaunchAgent is installed. VibePulse Bar is the only supervisor; enable “Launch at login” to start it with your session."
        }
        if agent.loaded {
            return "se.torget.tokenserver is loaded: launchd owns the service and restarts it by itself."
        }
        if agent.disabled {
            return "se.torget.tokenserver is installed but disabled (taken over by this app). Hand it back to let launchd run it again."
        }
        return "se.torget.tokenserver is installed but not loaded."
    }
}

private struct PathField: View {
    let title: String
    @Binding var path: String
    let chooseDirectories: Bool

    var body: some View {
        HStack {
            TextField(self.title, text: self.$path)
                .truncationMode(.middle)
            Button("Choose…") { self.choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !self.chooseDirectories
        panel.canChooseDirectories = self.chooseDirectories
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if !self.path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: self.path).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            self.path = url.path
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VibePulse Bar").font(.title2.weight(.semibold))
            Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
            Text("A menu bar home for the VibePulse tokenserver: start, pause and quit it from here, see who is serving the port, and read every agent's quota at a glance. The numbers come from the same service the panel polls; nothing is invented, and missing data stays a dash.")
                .fixedSize(horizontal: false, vertical: true)
            Link("github.com/niclasvestlund-YT/vibepulse",
                 destination: URL(string: "https://github.com/niclasvestlund-YT/vibepulse")!)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["VPBuildDescription"] ?? info["CFBundleShortVersionString"]) as? String
            ?? "development build"
    }
}
