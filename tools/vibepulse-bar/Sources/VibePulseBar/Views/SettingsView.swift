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
                Toggle("Start the server when the app opens",
                       isOn: self.$model.preferences.startServiceOnLaunch)
                Text("The menu bar app is the server. It does not launch a Python child.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Display") {
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
    @State private var draft = ServiceConfiguration()
    @State private var portText = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    let service = self.model.session.serviceSnapshot
                    HStack(spacing: 6) {
                        StatusDot(color: service.tone.color)
                        Text("\(service.headline) — \(service.detail(now: Date()))")
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Configuration", value: self.model.configurationSource.rawValue)
            }
            Section("Server") {
                TextField("Port", text: self.$portText)
                PathField(title: "Log file", path: self.$draft.logPath, chooseDirectories: false)
                ForEach(self.issues, id: \.message) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            Section("Plans") {
                TextField("Claude plan", text: self.$draft.claudePlan)
                TextField("Codex plan", text: self.$draft.codexPlan)
                Text("Plan names such as pro, max5x, or max20x. Blank leaves that plan unset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Relay") {
                TextField("Relay origin", text: self.$draft.relayURL)
                TextField("Mailbox", text: self.$draft.relayMailbox)
                Toggle("Publish interactions", isOn: self.$draft.publishInteractions)
                Toggle("Publish agent status", isOn: self.$draft.publishAgentStatus)
                Text("An https origin and mailbox. The device key and Mac token stay in their existing files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("GitHub") {
                TextField("Repository", text: self.$draft.githubRepo, prompt: Text("owner/name"))
            }
            Section {
                HStack {
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

    private var edited: ServiceConfiguration {
        var configuration = self.draft
        configuration.port = Int(self.portText.trimmingCharacters(in: .whitespaces))
            ?? ServiceConfiguration.defaultPort
        return configuration
    }

    private var issues: [ServiceConfiguration.Issue] { self.edited.validate() }

    private func load() {
        self.draft = self.model.configuration
        self.portText = String(self.draft.port)
    }

    private func apply(restart: Bool) {
        self.model.configuration = self.edited
        self.load()
        self.message = "Saved."
        if restart {
            self.model.restartService()
            self.message = "Saved; restarting the server."
        }
    }
}

private struct LaunchAgentSection: View {
    @Bindable var model: AppModel

    var body: some View {
        let agent = self.model.session.launchAgent
        let service = self.model.session.serviceSnapshot
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
            return "No LaunchAgent is installed. This app is the server; enable “Launch at login” to start it with your session."
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
            Text("A menu bar home for the VibePulse server: this app binds the port, and the menu reads that server's snapshot. Nothing is invented, and missing data stays a dash.")
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
