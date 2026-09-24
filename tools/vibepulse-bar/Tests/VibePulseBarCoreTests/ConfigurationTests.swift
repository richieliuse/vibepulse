import XCTest
@testable import VibePulseBarCore

final class ConfigurationTests: XCTestCase {
    func testSettingsKeepPortPlansRelayGitHubAndLog() throws {
        let configuration = ServiceConfiguration(
            port: 9001,
            claudePlan: "max20x",
            codexPlan: "pro",
            relayURL: "https://relay.example",
            relayMailbox: "vp_abcdefghijklmnop",
            publishInteractions: true,
            publishAgentStatus: false,
            githubRepo: "niclas/vibepulse",
            logPath: "/tmp/tokenserver.log")
        XCTAssertEqual(configuration.plans, ["claude": "max20x", "codex": "pro"])
        XCTAssertEqual(configuration.trimmedRelayURL, "https://relay.example")
        XCTAssertEqual(configuration.trimmedRelayMailbox, "vp_abcdefghijklmnop")
        XCTAssertEqual(configuration.trimmedGitHubRepo, "niclas/vibepulse")
        XCTAssertEqual(configuration.logPath, "/tmp/tokenserver.log")
        XCTAssertEqual(configuration.validate(), [])

        let data = try JSONEncoder().encode(configuration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["port"] as? Int, 9001)
        XCTAssertNil(object["pythonPath"])
        XCTAssertNil(object["scriptPath"])
        XCTAssertNil(object["arguments"])
        let decoded = try JSONDecoder().decode(ServiceConfiguration.self, from: data)
        XCTAssertEqual(decoded, configuration)
    }

    func testBlankPlansAndRelayAreOmitted() {
        let configuration = ServiceConfiguration(claudePlan: "  ", codexPlan: "", relayURL: "  ", githubRepo: " ")
        XCTAssertEqual(configuration.plans, [:])
        XCTAssertNil(configuration.trimmedRelayURL)
        XCTAssertNil(configuration.trimmedGitHubRepo)
    }

    func testInvalidPortIsTheOnlyStartupIssue() {
        XCTAssertEqual(ServiceConfiguration(port: 0).validate(), [.invalidPort(0)])
        XCTAssertEqual(ServiceConfiguration(port: 70_000).validate(), [.invalidPort(70_000)])
        XCTAssertEqual(ServiceConfiguration(port: 1).validate(), [])
        XCTAssertEqual(ServiceConfiguration(port: 65535).validate(), [])
    }

    func testLaunchctlParsing() {
        let printed = """
        gui/501/se.torget.tokenserver = {
        \tactive count = 1
        \tstate = running
        \tpid = 4242
        }
        """
        XCTAssertEqual(LaunchAgentControl.parsePID(printed), 4242)
        XCTAssertNil(LaunchAgentControl.parsePID("state = not running"))
        let disabled = """
        disabled services = {
        \t"com.apple.foo" => enabled
        \t"se.torget.tokenserver" => disabled
        }
        """
        XCTAssertTrue(LaunchAgentControl.parseDisabled(disabled, label: "se.torget.tokenserver"))
        XCTAssertFalse(LaunchAgentControl.parseDisabled(disabled, label: "com.apple.foo"))
        XCTAssertFalse(LaunchAgentControl.parseDisabled("", label: "se.torget.tokenserver"))
    }
}
