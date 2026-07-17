import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure.assertion(message)
    }
}

private final class MemoryServiceFileSystem: ServiceFileSystem {
    private(set) var files: [String: Data] = [:]
    private(set) var operations: [String] = []

    func seed(_ data: Data, at url: URL) {
        files[url.standardizedFileURL.path] = data
    }

    func fileExists(at url: URL) -> Bool {
        files[url.standardizedFileURL.path] != nil
    }

    func readData(at url: URL) throws -> Data {
        let path = url.standardizedFileURL.path
        guard let data = files[path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }

    func createDirectory(at url: URL) throws {
        operations.append("mkdir:\(url.standardizedFileURL.path)")
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let path = url.standardizedFileURL.path
        files[path] = data
        operations.append("write:\(path)")
    }

    func replaceItem(at destinationURL: URL, withItemAt temporaryURL: URL) throws {
        let destination = destinationURL.standardizedFileURL.path
        let temporary = temporaryURL.standardizedFileURL.path
        guard let data = files.removeValue(forKey: temporary) else {
            throw CocoaError(.fileNoSuchFile)
        }
        files[destination] = data
        operations.append("replace:\(temporary)->\(destination)")
    }

    func removeItem(at url: URL) throws {
        let path = url.standardizedFileURL.path
        files.removeValue(forKey: path)
        operations.append("remove:\(path)")
    }
}

private final class FakeServiceCommandRunner: ServiceCommandRunning {
    struct Call: Equatable {
        let arguments: [String]
        let timeout: TimeInterval
    }

    private(set) var calls: [Call] = []
    private(set) var bootstrapCount = 0
    var loaded: Bool
    var printPIDs: [Int32]
    var bootoutExitCode: Int32 = 0

    init(loaded: Bool = false, printPIDs: [Int32] = []) {
        self.loaded = loaded
        self.printPIDs = printPIDs
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ServiceCommandResult {
        calls.append(Call(arguments: arguments, timeout: timeout))
        switch arguments.first {
        case "print":
            guard loaded else {
                return ServiceCommandResult(exitCode: 113, stdout: "", stderr: "not found")
            }
            let pid = printPIDs.isEmpty ? 0 : printPIDs.removeFirst()
            return ServiceCommandResult(
                exitCode: 0,
                stdout: "state = running\npid = \(pid)\n",
                stderr: ""
            )
        case "bootout":
            if bootoutExitCode == 0 {
                loaded = false
            }
            return ServiceCommandResult(
                exitCode: bootoutExitCode,
                stdout: "",
                stderr: bootoutExitCode == 0 ? "" : "bootout failed"
            )
        case "bootstrap":
            bootstrapCount += 1
            loaded = true
            return ServiceCommandResult(exitCode: 0, stdout: "", stderr: "")
        case "enable", "kickstart":
            return ServiceCommandResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ServiceCommandResult(exitCode: 64, stdout: "", stderr: "unexpected")
        }
    }
}

private struct ServiceFixture {
    let root = URL(fileURLWithPath: "/tmp/mac-face-lock-service-tests", isDirectory: true)
    let appURL: URL
    let supportURL: URL
    let launchAgentsURL: URL
    let plistURL: URL
    let templateURL: URL
    let stateURL: URL
    let fileSystem = MemoryServiceFileSystem()
    let runner: FakeServiceCommandRunner

    init(loaded: Bool = false, printPIDs: [Int32] = []) throws {
        appURL = root.appendingPathComponent("Applications/Mac Face Lock.app")
        supportURL = root.appendingPathComponent("Library/Application Support/Mac Face Lock")
        launchAgentsURL = root.appendingPathComponent("Library/LaunchAgents")
        plistURL = launchAgentsURL.appendingPathComponent(
            "com.wuyi.mac-face-lock-agent.plist"
        )
        templateURL = root.appendingPathComponent(
            "release/com.wuyi.mac-face-lock-release.plist"
        )
        stateURL = supportURL.appendingPathComponent("data/state.json")
        runner = FakeServiceCommandRunner(loaded: loaded, printPIDs: printPIDs)
        fileSystem.seed(try Self.templateData(), at: templateURL)
    }

    func manager(
        pollAttempts: Int = 3
    ) -> ServiceManager {
        ServiceManager(
            appURL: appURL,
            supportURL: supportURL,
            launchAgentsURL: launchAgentsURL,
            templateURL: templateURL,
            fileSystem: fileSystem,
            commandRunner: runner,
            userID: 501,
            commandTimeout: 2,
            healthPollAttempts: pollAttempts,
            healthPollIntervalNanoseconds: 0
        )
    }

    func seedHealthyState(
        pid: Int32 = 42,
        camera: Bool = true,
        inputMonitoring: Bool = true,
        accessibility: Bool = true
    ) throws {
        let object: [String: Any] = [
            "status": "paused",
            "armed": false,
            "agent_pid": Int(pid),
            "camera_ready": camera,
            "input_monitoring_ready": inputMonitoring,
            "accessibility_ready": accessibility,
        ]
        fileSystem.seed(
            try JSONSerialization.data(withJSONObject: object),
            at: stateURL
        )
    }

    static func templateData() throws -> Data {
        let object: [String: Any] = [
            "Label": "com.wuyi.mac-face-lock-agent",
            "ProgramArguments": [
                "__APP_URL__/Contents/Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent",
                "--resources-dir",
                "__APP_URL__/Contents/Resources",
                "--support-dir",
                "__SUPPORT_URL__",
                "agent",
            ],
            "WorkingDirectory": "__SUPPORT_URL__",
            "StandardOutPath": "__SUPPORT_URL__/logs/agent-launchd.log",
            "StandardErrorPath": "__SUPPORT_URL__/logs/agent-launchd.error.log",
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
    }
}

@main
struct ServiceManagerTests {
    static func main() async throws {
        try await testInstallRendersOnlyApplicationAndSupportPaths()
        try await testFailedStableHealthRestoresPreviousPlistAndJob()
        try await testUninstallPreservesApplicationData()
        try await testUninstallDoesNotHideRunningJobRemovalFailure()
        try await testAgentPermissionFailureCannotReportHealthy()
        try await testMovedApplicationNeedsRepair()
        print("Service manager tests passed")
    }

    private static func testInstallRendersOnlyApplicationAndSupportPaths() async throws {
        let fixture = try ServiceFixture(printPIDs: [42, 42, 42])
        try fixture.seedHealthyState()

        try await fixture.manager().install(
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )

        let plistData = try fixture.fileSystem.readData(at: fixture.plistURL)
        let plist = try requireDictionary(plistData)
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let expectedProgram = fixture.appURL.appendingPathComponent(
            "Contents/Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
        ).path
        try require(arguments.first == expectedProgram, "release Agent path was not embedded")
        try require(
            arguments == [
                expectedProgram,
                "--resources-dir",
                fixture.appURL.appendingPathComponent("Contents/Resources").path,
                "--support-dir",
                fixture.supportURL.path,
                "agent",
            ],
            "release arguments were not limited to application and support paths"
        )
        let rendered = String(decoding: plistData, as: UTF8.self)
        try require(!rendered.contains(".venv"), "release plist referenced a virtual environment")
        try require(!rendered.contains("__APP_URL__"), "application token was not rendered")
        try require(!rendered.contains("__SUPPORT_URL__"), "support token was not rendered")
        let controlURL = fixture.supportURL.appendingPathComponent("data/control.json")
        let control = try JSONSerialization.jsonObject(
            with: fixture.fileSystem.readData(at: controlURL)
        ) as? [String: Any]
        try require(
            control?["protection_enabled"] as? Bool == false,
            "service install did not force protection off during onboarding"
        )
        try require(
            fixture.runner.calls.allSatisfy { $0.timeout == 2 },
            "a launchctl call was not bounded by the configured timeout"
        )
    }

    private static func testFailedStableHealthRestoresPreviousPlistAndJob() async throws {
        let fixture = try ServiceFixture(
            loaded: true,
            printPIDs: [99, 41, 42, 42]
        )
        let previous: [String: Any] = [
            "Label": "com.wuyi.mac-face-lock-agent",
            "ProgramArguments": ["/previous/MacFaceLockAgent", "/previous/project"],
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        let previousData = try PropertyListSerialization.data(
            fromPropertyList: previous,
            format: .xml,
            options: 0
        )
        fixture.fileSystem.seed(previousData, at: fixture.plistURL)
        try fixture.seedHealthyState(pid: 42)

        do {
            try await fixture.manager(pollAttempts: 3).install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion("unstable service install unexpectedly succeeded")
        } catch is ServiceManagerError {
            // Expected.
        }

        let restoredData = try fixture.fileSystem.readData(at: fixture.plistURL)
        try require(
            restoredData == previousData,
            "failed install did not restore the previous plist byte-for-byte"
        )
        try require(
            fixture.runner.bootstrapCount == 2,
            "failed install did not bootstrap the restored previous job"
        )
        try require(
            fixture.fileSystem.operations.contains {
                $0.contains(".backup") && $0.hasPrefix("write:")
            },
            "previous plist was not preserved in an atomic sibling backup"
        )
        try require(
            fixture.fileSystem.operations.filter { $0.hasPrefix("replace:") }.count >= 2,
            "new and rollback plists were not atomically replaced"
        )
    }

    private static func testUninstallPreservesApplicationData() async throws {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
        let ownerURL = fixture.supportURL.appendingPathComponent("data/owner_face.npy")
        let controlURL = fixture.supportURL.appendingPathComponent("data/control.json")
        fixture.fileSystem.seed(Data("plist".utf8), at: fixture.plistURL)
        fixture.fileSystem.seed(Data("owner".utf8), at: ownerURL)
        fixture.fileSystem.seed(Data("control".utf8), at: controlURL)

        try await fixture.manager().uninstallPreservingData()

        try require(
            !fixture.fileSystem.fileExists(at: fixture.plistURL),
            "uninstall retained the release plist"
        )
        try require(
            fixture.fileSystem.fileExists(at: ownerURL)
                && fixture.fileSystem.fileExists(at: controlURL),
            "uninstall deleted application data"
        )
        try require(
            fixture.fileSystem.operations.filter { $0.hasPrefix("remove:") }
                == ["remove:\(fixture.plistURL.path)"],
            "uninstall removed more than the service plist"
        )
    }

    private static func testUninstallDoesNotHideRunningJobRemovalFailure() async throws {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
        fixture.runner.bootoutExitCode = 5
        fixture.fileSystem.seed(Data("plist".utf8), at: fixture.plistURL)

        do {
            try await fixture.manager().uninstallPreservingData()
            throw TestFailure.assertion("uninstall hid a running-job removal failure")
        } catch is ServiceManagerError {
            // Expected.
        }

        try require(
            fixture.fileSystem.fileExists(at: fixture.plistURL),
            "uninstall removed the plist while the running job remained loaded"
        )
    }

    private static func testAgentPermissionFailureCannotReportHealthy() async throws {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
        try fixture.seedHealthyState(inputMonitoring: false)
        let rendered = try renderTemplate(
            try fixture.fileSystem.readData(at: fixture.templateURL),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(rendered, at: fixture.plistURL)

        let status = await fixture.manager().status()

        try require(status.state == .unhealthy, "Agent permission denial reported healthy")
        try require(status.pid == 42, "running Agent PID was not retained in unhealthy status")
        try require(status.cameraReady, "camera readiness was lost")
        try require(!status.inputMonitoringReady, "input monitoring denial was ignored")
        try require(status.accessibilityReady, "accessibility readiness was lost")
    }

    private static func testMovedApplicationNeedsRepair() async throws {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
        let oldAppURL = fixture.root.appendingPathComponent("Old/Mac Face Lock.app")
        let rendered = try renderTemplate(
            try fixture.fileSystem.readData(at: fixture.templateURL),
            appURL: oldAppURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(rendered, at: fixture.plistURL)

        let status = await fixture.manager().status()

        try require(status.state == .needsRepair, "moved application path was not repairable")
        try require(
            fixture.runner.calls.isEmpty,
            "path mismatch unnecessarily trusted the running launchd job"
        )
    }

    private static func renderTemplate(
        _ data: Data,
        appURL: URL,
        supportURL: URL
    ) throws -> Data {
        let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        func replacing(_ value: Any) -> Any {
            if let string = value as? String {
                return string
                    .replacingOccurrences(of: "__APP_URL__", with: appURL.path)
                    .replacingOccurrences(of: "__SUPPORT_URL__", with: supportURL.path)
            }
            if let array = value as? [Any] {
                return array.map(replacing)
            }
            if let dictionary = value as? [String: Any] {
                return dictionary.mapValues(replacing)
            }
            return value
        }
        return try PropertyListSerialization.data(
            fromPropertyList: replacing(object),
            format: .xml,
            options: 0
        )
    }

    private static func requireDictionary(_ data: Data) throws -> [String: Any] {
        guard let dictionary = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw TestFailure.assertion("plist did not decode as a dictionary")
        }
        return dictionary
    }
}
