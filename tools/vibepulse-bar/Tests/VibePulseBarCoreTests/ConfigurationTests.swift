import XCTest
@testable import VibePulseBarCore

final class ConfigurationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpbar-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    private func writePlist(_ dictionary: [String: Any]) throws -> String {
        let url = self.directory.appendingPathComponent("se.torget.tokenserver.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url)
        return url.path
    }

    func testImportsLaunchAgentWithWrapperAndPort() throws {
        let path = try self.writePlist([
            "Label": "se.torget.tokenserver",
            "ProgramArguments": ["/Users/me/vp/.venv/bin/python", "-u", "tools/run-tokenserver.py",
                                 "--publish-url", "https://relay.example", "--port", "9001"],
            "WorkingDirectory": "/Users/me/vp",
            "EnvironmentVariables": ["TORGET_PLAN": "max20"],
            "StandardErrorPath": "/tmp/tokenserver.log",
        ])
        let configuration = try ServiceConfiguration.fromLaunchAgent(at: path)
        XCTAssertEqual(configuration.pythonPath, "/Users/me/vp/.venv/bin/python")
        XCTAssertEqual(configuration.scriptPath, "/Users/me/vp/tools/run-tokenserver.py")
        XCTAssertEqual(configuration.arguments, ["--publish-url", "https://relay.example"],
                       "installer arguments survive; the port moves to its own field")
        XCTAssertEqual(configuration.port, 9001)
        XCTAssertEqual(configuration.effectivePort, 9001)
        XCTAssertEqual(configuration.environment, ["TORGET_PLAN": "max20"])
        XCTAssertEqual(configuration.logPath, "/tmp/tokenserver.log")
        XCTAssertEqual(configuration.commandLine, [
            "/Users/me/vp/.venv/bin/python", "-u", "/Users/me/vp/tools/run-tokenserver.py",
            "--publish-url", "https://relay.example", "--port", "9001",
        ])
    }

    func testRejectsForeignLaunchAgents() throws {
        let other = try self.writePlist(["Label": "com.example.other", "ProgramArguments": ["/bin/sh", "-u", "x"]])
        XCTAssertThrowsError(try ServiceConfiguration.fromLaunchAgent(at: other)) {
            XCTAssertEqual($0 as? ServiceConfiguration.ImportError, .notVibePulse)
        }
        let shell = try self.writePlist(["Label": "se.torget.tokenserver", "ProgramArguments": ["/bin/sh", "-c", "x"]])
        XCTAssertThrowsError(try ServiceConfiguration.fromLaunchAgent(at: shell)) {
            XCTAssertEqual($0 as? ServiceConfiguration.ImportError, .unrecognizedCommand)
        }
        XCTAssertThrowsError(try ServiceConfiguration.fromLaunchAgent(at: "/nonexistent.plist")) {
            XCTAssertEqual($0 as? ServiceConfiguration.ImportError, .missing)
        }
    }

    func testDefaultPortIsNotRepeated() {
        let configuration = ServiceConfiguration(pythonPath: "/usr/bin/python3", scriptPath: "/x/tokenserver.py")
        XCTAssertEqual(configuration.commandLine, ["/usr/bin/python3", "-u", "/x/tokenserver.py"])
        XCTAssertEqual(configuration.resolvedWorkingDirectory, "/x")
        var explicit = configuration
        explicit.arguments = ["--port=9100"]
        explicit.port = 9200
        XCTAssertEqual(explicit.effectivePort, 9100, "an explicit --port argument wins")
        XCTAssertEqual(explicit.commandLine.last, "--port=9100")
    }

    func testEnvironmentAppendsToolPathsAndKeepsSystemFirst() {
        let configuration = ServiceConfiguration(pythonPath: "/usr/bin/python3", scriptPath: "/x.py",
                                                 environment: ["TORGET_PLAN": "pro"])
        let environment = configuration.processEnvironment(base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"])
        let path = environment["PATH"]!.split(separator: ":").map(String.init)
        XCTAssertEqual(Array(path.prefix(2)), ["/usr/bin", "/bin"])
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertEqual(path.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertEqual(environment["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(environment["TORGET_PLAN"], "pro")
        XCTAssertEqual(environment["HOME"], "/Users/me")
    }

    func testValidation() {
        let broken = ServiceConfiguration(pythonPath: "/nope/python", scriptPath: "/nope/tokenserver.py", port: 0)
        XCTAssertEqual(broken.validate(), [
            .pythonMissing("/nope/python"), .scriptMissing("/nope/tokenserver.py"), .invalidPort(0),
        ])
    }

    func testFindsRepositoryFromNestedPath() throws {
        let server = self.directory.appendingPathComponent("tools/tokenserver")
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: server.appendingPathComponent("tokenserver.py").path, contents: nil)
        let nested = self.directory.appendingPathComponent("tools/vibepulse-bar/.build/release")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let found = try XCTUnwrap(ServiceConfiguration.findRepository(from: nested))
        XCTAssertEqual(found.resolvingSymlinksInPath().path, self.directory.resolvingSymlinksInPath().path)
        let configuration = ServiceConfiguration.fromRepository(found)
        XCTAssertTrue(configuration.scriptPath.hasSuffix("tools/tokenserver/tokenserver.py"))
    }

    func testRestartPolicyBacksOffAndResets() {
        let policy = RestartPolicy()
        XCTAssertEqual((1...6).map(policy.delay(forAttempt:)), [5, 10, 20, 40, 60, 60])
        XCTAssertEqual(policy.nextAttempt(previous: 3, runtime: 4), 4)
        XCTAssertEqual(policy.nextAttempt(previous: 3, runtime: 300), 1, "a stable run starts a fresh ladder")
    }

    func testLaunchctlParsing() {
        let printed = """
        gui/501/se.torget.tokenserver = {
        \tactive count = 1
        \tstate = running
        \tpid = 36670
        }
        """
        XCTAssertEqual(LaunchAgentControl.parsePID(printed), 36670)
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
