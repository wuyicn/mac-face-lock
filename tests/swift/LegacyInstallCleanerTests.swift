import Darwin
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

private final class RecordingServiceCommandRunner: ServiceCommandRunning {
    private(set) var calls: [(URL, [String], TimeInterval)] = []

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ServiceCommandResult {
        calls.append((executableURL, arguments, timeout))
        return ServiceCommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private struct LegacyCleanerFixture {
    static let agentName = "com.wuyi.mac-face-lock-agent.plist"
    static let statusName = "com.wuyi.mac-face-lock-status.plist"
    static let sourcePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    let container: URL
    let home: URL
    let legacyRoot: URL
    let otherLegacyRoot: URL
    let outsideRoot: URL
    let appURL: URL
    let supportURL: URL
    let launchAgentsURL: URL
    let commandRunner: RecordingServiceCommandRunner
    let cleaner: LegacyInstallCleaner

    init(appURLInsideLegacyRoot: Bool = false) throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mac-face-lock-legacy-cleaner-\(UUID().uuidString)",
                isDirectory: true
            )
        home = container.appendingPathComponent("home", isDirectory: true)
        legacyRoot = home.appendingPathComponent("legacy-source", isDirectory: true)
        otherLegacyRoot = home.appendingPathComponent(
            "other-legacy-source",
            isDirectory: true
        )
        outsideRoot = container.appendingPathComponent("outside-source", isDirectory: true)
        appURL = appURLInsideLegacyRoot
            ? legacyRoot.appendingPathComponent(
                "dist/Mac Face Lock.app",
                isDirectory: true
            )
            : container.appendingPathComponent("Mac Face Lock.app", isDirectory: true)
        supportURL = home.appendingPathComponent(
            "Library/Application Support/Mac Face Lock",
            isDirectory: true
        )
        launchAgentsURL = home.appendingPathComponent(
            "Library/LaunchAgents",
            isDirectory: true
        )

        for directory in [
            legacyRoot,
            otherLegacyRoot,
            outsideRoot,
            appURL,
            supportURL,
            launchAgentsURL,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        commandRunner = RecordingServiceCommandRunner()
        cleaner = LegacyInstallCleaner(
            homeURL: home,
            appURL: appURL,
            supportURL: supportURL,
            commandRunner: commandRunner,
            userID: getuid()
        )
    }

    var agentURL: URL {
        launchAgentsURL.appendingPathComponent(Self.agentName)
    }

    var statusURL: URL {
        launchAgentsURL.appendingPathComponent(Self.statusName)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }

    func writeCurrentAgentPlist(root: URL? = nil) throws {
        let root = root ?? legacyRoot
        try writePlist(
            currentAgentDictionary(root: root),
            to: agentURL
        )
    }

    func writeHistoricalAgentPlist(
        root: URL? = nil,
        pythonPath: String? = nil
    ) throws {
        let root = root ?? legacyRoot
        var dictionary = currentAgentDictionary(root: root)
        dictionary["ProgramArguments"] = [
            sourceAgentExecutable(root: root),
            "-u",
            "agent.py",
        ]
        var environment = currentAgentEnvironment()
        environment["PYTHONPATH"] = pythonPath
            ?? root.appendingPathComponent(
                ".venv/lib/python3.9/site-packages"
            ).path
        dictionary["EnvironmentVariables"] = environment
        try writePlist(dictionary, to: agentURL)
    }

    func writeUnifiedStatusPlist(root: URL? = nil) throws {
        let root = root ?? legacyRoot
        try writePlist(
            unifiedStatusDictionary(root: root),
            to: statusURL
        )
    }

    func writeHistoricalStatusPlist(root: URL? = nil) throws {
        let root = root ?? legacyRoot
        try writePlist(
            historicalStatusDictionary(root: root),
            to: statusURL
        )
    }

    func writeReleaseAgentPlist() throws {
        try writePlist(
            releaseAgentDictionary(),
            to: agentURL
        )
    }

    func writePlist(_ dictionary: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    func currentAgentDictionary(root: URL) -> [String: Any] {
        [
            "Label": "com.wuyi.mac-face-lock-agent",
            "ProgramArguments": [
                sourceAgentExecutable(root: root),
                root.path,
            ],
            "WorkingDirectory": root.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": root.appendingPathComponent(
                "logs/agent.out.log"
            ).path,
            "StandardErrorPath": root.appendingPathComponent(
                "logs/agent.err.log"
            ).path,
            "EnvironmentVariables": currentAgentEnvironment(),
        ]
    }

    func currentAgentEnvironment() -> [String: String] {
        [
            "PYTHONUNBUFFERED": "1",
            "PATH": Self.sourcePath,
        ]
    }

    func unifiedStatusDictionary(root: URL) -> [String: Any] {
        [
            "Label": "com.wuyi.mac-face-lock-status",
            "ProgramArguments": [
                root.appendingPathComponent(
                    "dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock"
                ).path,
                root.path,
            ],
            "WorkingDirectory": root.path,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": root.appendingPathComponent(
                "logs/status.out.log"
            ).path,
            "StandardErrorPath": root.appendingPathComponent(
                "logs/status.err.log"
            ).path,
        ]
    }

    func historicalStatusDictionary(root: URL) -> [String: Any] {
        [
            "Label": "com.wuyi.mac-face-lock-status",
            "ProgramArguments": [
                root.appendingPathComponent(
                    "dist/Mac Face Lock Status.app/Contents/MacOS/MacFaceLockStatus"
                ).path,
                root.path,
            ],
            "WorkingDirectory": root.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": root.appendingPathComponent(
                "logs/status.out.log"
            ).path,
            "StandardErrorPath": root.appendingPathComponent(
                "logs/status.err.log"
            ).path,
        ]
    }

    func releaseAgentDictionary() -> [String: Any] {
        [
            "Label": "com.wuyi.mac-face-lock-agent",
            "ProgramArguments": [
                appURL.appendingPathComponent(
                    "Contents/Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
                ).path,
                "--resources-dir",
                appURL.appendingPathComponent("Contents/Resources").path,
                "--support-dir",
                supportURL.path,
                "agent",
            ],
            "WorkingDirectory": supportURL.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": supportURL.appendingPathComponent(
                "logs/agent-launchd.log"
            ).path,
            "StandardErrorPath": supportURL.appendingPathComponent(
                "logs/agent-launchd.error.log"
            ).path,
        ]
    }

    func sourceAgentExecutable(root: URL) -> String {
        root.appendingPathComponent(
            "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
        ).path
    }
}

@main
struct LegacyInstallCleanerTests {
    static func main() throws {
        try testRejectsCurrentAppInsideCandidateRoot()
        try testRecognizesInstalledCurrentPair()
        try testRecognizesInstalledHistoricalPair()
        try testRecognizesHistoricalStatusSchema()
        try testNoPlistsIsNotFound()
        try testCurrentReleaseAgentWithoutStatusIsNotFound()
        try testOnlyOneSourcePlistIsAmbiguous()
        try testMixedReleaseAndSourcePairIsAmbiguous()
        try testDifferentRootsAreAmbiguous()
        try testRootOutsideSuppliedHomeIsAmbiguous()
        try testUnknownArgumentIsAmbiguous()
        try testUnknownFieldCombinationIsAmbiguous()
        try testExternalPythonPathIsAmbiguous()
        try testTraversingPythonPathIsAmbiguous()
        try testIntegerBooleanFieldsAreAmbiguous()
        try testSymlinkPlistIsAmbiguous()
        try testHardLinkPlistIsAmbiguous()
        try testOversizedPlistIsAmbiguous()
        print("Legacy install cleaner tests passed")
    }

    private static func testRejectsCurrentAppInsideCandidateRoot() throws {
        let fixture = try LegacyCleanerFixture(appURLInsideLegacyRoot: true)
        defer { fixture.remove() }
        try fixture.writeCurrentAgentPlist()
        try fixture.writeUnifiedStatusPlist()

        guard case .ambiguous(let message) = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("current app inside source root was confirmed")
        }
        try require(
            message == "当前应用位于旧版源码目录内，无法自动确认。",
            "self-candidate defense returned an unexpected message"
        )
        try require(
            fixture.commandRunner.calls.isEmpty,
            "self-candidate inspection unexpectedly ran a service command"
        )
    }

    private static func testRecognizesInstalledCurrentPair() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeCurrentAgentPlist()
        try fixture.writeUnifiedStatusPlist()

        let result = fixture.cleaner.inspect()
        guard case .confirmed(let candidate) = result else {
            throw TestFailure.assertion("current source pair was not confirmed: \(result)")
        }
        try require(candidate.rootURL == fixture.legacyRoot, "wrong current source root")
        try require(candidate.rootIdentity.inode != 0, "source root identity was empty")
        try require(candidate.agentPlistIdentity.inode != 0, "agent identity was empty")
        try require(candidate.statusPlistIdentity.inode != 0, "status identity was empty")
        try require(
            fixture.commandRunner.calls.isEmpty,
            "inspection unexpectedly ran a service command"
        )
    }

    private static func testRecognizesInstalledHistoricalPair() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeHistoricalAgentPlist()
        try fixture.writeUnifiedStatusPlist()

        let result = fixture.cleaner.inspect()
        guard case .confirmed(let candidate) = result else {
            throw TestFailure.assertion("historical source pair was not confirmed: \(result)")
        }
        try require(candidate.rootURL == fixture.legacyRoot, "wrong source root")
    }

    private static func testRecognizesHistoricalStatusSchema() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeCurrentAgentPlist()
        try fixture.writeHistoricalStatusPlist()

        guard case .confirmed = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("historical status schema was not confirmed")
        }
    }

    private static func testNoPlistsIsNotFound() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }

        try require(fixture.cleaner.inspect() == .notFound, "empty install was not found")
    }

    private static func testCurrentReleaseAgentWithoutStatusIsNotFound() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeReleaseAgentPlist()

        try require(
            fixture.cleaner.inspect() == .notFound,
            "current release Agent was treated as legacy"
        )
    }

    private static func testOnlyOneSourcePlistIsAmbiguous() throws {
        do {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.writeCurrentAgentPlist()
            guard case .ambiguous = fixture.cleaner.inspect() else {
                throw TestFailure.assertion("lone source Agent was accepted")
            }
        }
        do {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.writeUnifiedStatusPlist()
            guard case .ambiguous = fixture.cleaner.inspect() else {
                throw TestFailure.assertion("lone source Status was accepted")
            }
        }
    }

    private static func testMixedReleaseAndSourcePairIsAmbiguous() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeReleaseAgentPlist()
        try fixture.writeUnifiedStatusPlist()

        guard case .ambiguous = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("mixed release/source pair was accepted")
        }
    }

    private static func testDifferentRootsAreAmbiguous() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeCurrentAgentPlist()
        try fixture.writeUnifiedStatusPlist(root: fixture.otherLegacyRoot)

        guard case .ambiguous = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("different source roots were accepted")
        }
    }

    private static func testRootOutsideSuppliedHomeIsAmbiguous() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeCurrentAgentPlist(root: fixture.outsideRoot)
        try fixture.writeUnifiedStatusPlist(root: fixture.outsideRoot)

        guard case .ambiguous = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("source root outside supplied home was accepted")
        }
    }

    private static func testUnknownArgumentIsAmbiguous() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        var dictionary = fixture.currentAgentDictionary(root: fixture.legacyRoot)
        dictionary["ProgramArguments"] = [
            fixture.sourceAgentExecutable(root: fixture.legacyRoot),
            fixture.legacyRoot.path,
            "--unknown",
        ]
        try fixture.writePlist(dictionary, to: fixture.agentURL)
        try fixture.writeUnifiedStatusPlist()

        guard case .ambiguous = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("unknown Agent argument was accepted")
        }
    }

    private static func testUnknownFieldCombinationIsAmbiguous() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        var dictionary = fixture.currentAgentDictionary(root: fixture.legacyRoot)
        var environment = fixture.currentAgentEnvironment()
        environment["PYTHONPATH"] = fixture.legacyRoot.appendingPathComponent(
            ".venv/lib/python3.11/site-packages"
        ).path
        dictionary["EnvironmentVariables"] = environment
        try fixture.writePlist(dictionary, to: fixture.agentURL)
        try fixture.writeUnifiedStatusPlist()

        guard case .ambiguous = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("unknown current/historical field mix was accepted")
        }
    }

    private static func testExternalPythonPathIsAmbiguous() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeHistoricalAgentPlist(
            pythonPath: fixture.outsideRoot.appendingPathComponent(
                ".venv/lib/python3.9/site-packages"
            ).path
        )
        try fixture.writeUnifiedStatusPlist()

        guard case .ambiguous(let message) = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("external PYTHONPATH was accepted")
        }
        try require(
            message == "旧版 PYTHONPATH 不属于已知源码环境。",
            "external PYTHONPATH returned an unsafe or unexpected message"
        )
    }

    private static func testTraversingPythonPathIsAmbiguous() throws {
        for (label, suffix) in [
            (
                "traversing",
                "/.venv/lib/python3.11/../../../../outside/site-packages"
            ),
            ("dot", "/.venv/lib/./python3.11/site-packages"),
            ("repeated", "/.venv/lib/python3.11//site-packages"),
            ("extra", "/.venv/lib/python3.11/extra/site-packages"),
        ] {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.writeHistoricalAgentPlist(
                pythonPath: fixture.legacyRoot.path + suffix
            )
            try fixture.writeUnifiedStatusPlist()

            guard case .ambiguous(let message) = fixture.cleaner.inspect() else {
                throw TestFailure.assertion("\(label) PYTHONPATH was accepted")
            }
            try require(
                message == "旧版 PYTHONPATH 不属于已知源码环境。",
                "\(label) PYTHONPATH returned an unexpected message"
            )
        }
    }

    private static func testIntegerBooleanFieldsAreAmbiguous() throws {
        for field in ["RunAtLoad", "KeepAlive"] {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            var agent = fixture.currentAgentDictionary(root: fixture.legacyRoot)
            agent[field] = NSNumber(value: 1)
            try fixture.writePlist(agent, to: fixture.agentURL)
            try fixture.writeUnifiedStatusPlist()

            guard case .ambiguous = fixture.cleaner.inspect() else {
                throw TestFailure.assertion(
                    "integer current Agent \(field) was accepted"
                )
            }
        }

        for field in ["RunAtLoad", "KeepAlive"] {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            var agent = fixture.currentAgentDictionary(root: fixture.legacyRoot)
            agent["ProgramArguments"] = [
                fixture.sourceAgentExecutable(root: fixture.legacyRoot),
                "-u",
                "agent.py",
            ]
            var environment = fixture.currentAgentEnvironment()
            environment["PYTHONPATH"] = fixture.legacyRoot.appendingPathComponent(
                ".venv/lib/python3.11/site-packages"
            ).path
            agent["EnvironmentVariables"] = environment
            agent[field] = NSNumber(value: 1)
            try fixture.writePlist(agent, to: fixture.agentURL)
            try fixture.writeUnifiedStatusPlist()

            guard case .ambiguous = fixture.cleaner.inspect() else {
                throw TestFailure.assertion(
                    "integer historical Agent \(field) was accepted"
                )
            }
        }

        do {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.writeCurrentAgentPlist()
            var status = fixture.unifiedStatusDictionary(root: fixture.legacyRoot)
            status["RunAtLoad"] = NSNumber(value: 1)
            try fixture.writePlist(status, to: fixture.statusURL)

            guard case .ambiguous = fixture.cleaner.inspect() else {
                throw TestFailure.assertion(
                    "integer current Status RunAtLoad was accepted"
                )
            }
        }

        do {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.writeCurrentAgentPlist()
            var status = fixture.unifiedStatusDictionary(root: fixture.legacyRoot)
            status["KeepAlive"] = [
                "SuccessfulExit": NSNumber(value: 0),
            ]
            try fixture.writePlist(status, to: fixture.statusURL)

            guard case .ambiguous = fixture.cleaner.inspect() else {
                throw TestFailure.assertion(
                    "integer nested SuccessfulExit was accepted"
                )
            }
        }

        for field in ["RunAtLoad", "KeepAlive"] {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.writeCurrentAgentPlist()
            var status = fixture.historicalStatusDictionary(root: fixture.legacyRoot)
            status[field] = NSNumber(value: 1)
            try fixture.writePlist(status, to: fixture.statusURL)

            guard case .ambiguous = fixture.cleaner.inspect() else {
                throw TestFailure.assertion(
                    "integer historical Status \(field) was accepted"
                )
            }
        }

        for field in ["RunAtLoad", "KeepAlive"] {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            var release = fixture.releaseAgentDictionary()
            release[field] = NSNumber(value: 1)
            try fixture.writePlist(release, to: fixture.agentURL)

            guard case .ambiguous = fixture.cleaner.inspect() else {
                throw TestFailure.assertion(
                    "integer release Agent \(field) was accepted"
                )
            }
        }
    }

    private static func testSymlinkPlistIsAmbiguous() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        let externalPlist = fixture.container.appendingPathComponent("external-agent.plist")
        try fixture.writePlist(
            fixture.currentAgentDictionary(root: fixture.legacyRoot),
            to: externalPlist
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.agentURL,
            withDestinationURL: externalPlist
        )
        try fixture.writeUnifiedStatusPlist()

        guard case .ambiguous = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("symlink plist was accepted")
        }
    }

    private static func testHardLinkPlistIsAmbiguous() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        let original = fixture.launchAgentsURL.appendingPathComponent("agent-original.plist")
        try fixture.writePlist(
            fixture.currentAgentDictionary(root: fixture.legacyRoot),
            to: original
        )
        guard link(original.path, fixture.agentURL.path) == 0 else {
            throw TestFailure.assertion("could not create hard-link fixture: \(errno)")
        }
        try fixture.writeUnifiedStatusPlist()

        guard case .ambiguous = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("hard-link plist was accepted")
        }
    }

    private static func testOversizedPlistIsAmbiguous() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try Data(repeating: 0x20, count: 1_048_577).write(to: fixture.agentURL)
        try fixture.writeUnifiedStatusPlist()

        guard case .ambiguous = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("plist larger than 1 MiB was accepted")
        }
    }
}
