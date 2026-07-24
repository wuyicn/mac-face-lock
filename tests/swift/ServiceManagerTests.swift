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

private enum InjectedFileSystemError: Error {
    case createDirectory(String)
    case removeItem(String)
}

private final class MemoryServiceFileSystem: ServiceFileSystem {
    private(set) var files: [String: Data] = [:]
    private(set) var operations: [String] = []
    private(set) var readPaths: [String] = []
    private var readSequences: [String: [Data]] = [:]
    private var createDirectoryFailurePaths: Set<String> = []
    private var removeFailurePaths: Set<String> = []
    var onRemove: ((URL) -> Void)?

    func seed(_ data: Data, at url: URL) {
        files[url.standardizedFileURL.path] = data
    }

    func seedReadSequence(_ data: [Data], at url: URL) {
        readSequences[url.standardizedFileURL.path] = data
    }

    func failCreateDirectory(at url: URL) {
        createDirectoryFailurePaths.insert(url.standardizedFileURL.path)
    }

    func failRemoveItem(at url: URL) {
        removeFailurePaths.insert(url.standardizedFileURL.path)
    }

    func fileExists(at url: URL) -> Bool {
        files[url.standardizedFileURL.path] != nil
    }

    func readData(at url: URL) throws -> Data {
        let path = url.standardizedFileURL.path
        readPaths.append(path)
        if var sequence = readSequences[path], !sequence.isEmpty {
            let data = sequence.removeFirst()
            readSequences[path] = sequence
            files[path] = data
            return data
        }
        guard let data = files[path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }

    func createDirectory(at url: URL) throws {
        let path = url.standardizedFileURL.path
        operations.append("mkdir:\(path)")
        if createDirectoryFailurePaths.contains(path) {
            throw InjectedFileSystemError.createDirectory(path)
        }
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
        operations.append("remove:\(path)")
        if removeFailurePaths.contains(path) {
            throw InjectedFileSystemError.removeItem(path)
        }
        files.removeValue(forKey: path)
        onRemove?(url.standardizedFileURL)
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
    private var loadedTargets: [String: Bool] = [:]
    private var printPIDsByTarget: [String: [Int32]] = [:]
    private var bootoutPrintsBeforeAbsentByTarget: [String: Int] = [:]
    private var bootoutPendingTargets: Set<String> = []
    var bootoutExitCode: Int32 = 0
    var printError: Error?
    var unloadedPrintExitCode: Int32 = 113
    var onLoadedPrint: ((TimeInterval) -> Void)?

    init(loaded: Bool = false, printPIDs: [Int32] = []) {
        self.loaded = loaded
        self.printPIDs = printPIDs
    }

    func seedLoadedTarget(_ target: String, printPIDs: [Int32]) {
        loadedTargets[target] = true
        printPIDsByTarget[target] = printPIDs
    }

    func seedUnloadedTarget(_ target: String, printPIDs: [Int32] = []) {
        loadedTargets[target] = false
        printPIDsByTarget[target] = printPIDs
    }

    func delayBootout(of target: String, loadedPrintsBeforeAbsent: Int) {
        bootoutPrintsBeforeAbsentByTarget[target] = loadedPrintsBeforeAbsent
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ServiceCommandResult {
        calls.append(Call(arguments: arguments, timeout: timeout))
        switch arguments.first {
        case "print":
            if let printError {
                throw printError
            }
            let target = arguments.last ?? ""
            let targetLoaded = loadedTargets[target]
                ?? (target.hasSuffix("/com.wuyi.mac-face-lock-background")
                    ? loaded
                    : false)
            guard targetLoaded else {
                return ServiceCommandResult(
                    exitCode: unloadedPrintExitCode,
                    stdout: "",
                    stderr: "print failed"
                )
            }
            onLoadedPrint?(timeout)
            var targetPIDs = printPIDsByTarget[target] ?? []
            let pid: Int32
            if targetPIDs.isEmpty {
                pid = printPIDs.isEmpty ? 0 : printPIDs.removeFirst()
            } else {
                pid = targetPIDs.removeFirst()
                printPIDsByTarget[target] = targetPIDs
            }
            if bootoutPendingTargets.contains(target),
               let remaining = bootoutPrintsBeforeAbsentByTarget[target],
               remaining > 0 {
                let nextRemaining = remaining - 1
                bootoutPrintsBeforeAbsentByTarget[target] = nextRemaining
                if nextRemaining == 0 {
                    loadedTargets[target] = false
                    bootoutPendingTargets.remove(target)
                }
            }
            return ServiceCommandResult(
                exitCode: 0,
                stdout: "state = running\npid = \(pid)\n",
                stderr: ""
            )
        case "bootout":
            if bootoutExitCode == 0 {
                let target = arguments.last ?? ""
                if (bootoutPrintsBeforeAbsentByTarget[target] ?? 0) == 0 {
                    loadedTargets[target] = false
                    if target.hasSuffix(
                        "/com.wuyi.mac-face-lock-background"
                    ) {
                        loaded = false
                    }
                } else {
                    bootoutPendingTargets.insert(target)
                }
            }
            return ServiceCommandResult(
                exitCode: bootoutExitCode,
                stdout: "",
                stderr: bootoutExitCode == 0 ? "" : "bootout failed"
            )
        case "bootstrap":
            bootstrapCount += 1
            let plistPath = arguments.last ?? ""
            let label = URL(fileURLWithPath: plistPath)
                .deletingPathExtension()
                .lastPathComponent
            loadedTargets["\(arguments.dropLast().last ?? "")/\(label)"] = true
            if label == "com.wuyi.mac-face-lock-background" {
                loaded = true
            }
            return ServiceCommandResult(exitCode: 0, stdout: "", stderr: "")
        case "enable", "kickstart":
            return ServiceCommandResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ServiceCommandResult(exitCode: 64, stdout: "", stderr: "unexpected")
        }
    }
}

private final class ManualServiceClock {
    private(set) var now: TimeInterval = 0
    private(set) var sleeps: [UInt64] = []

    func advance(by seconds: TimeInterval) {
        now += seconds
    }

    func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(nanoseconds)
        now += TimeInterval(nanoseconds) / 1_000_000_000
    }
}

private struct ServiceFixture {
    let root = URL(fileURLWithPath: "/tmp/mac-face-lock-service-tests", isDirectory: true)
    let appURL: URL
    let supportURL: URL
    let launchAgentsURL: URL
    let plistURL: URL
    let backgroundPlistURL: URL
    let legacyPlistURL: URL
    let templateURL: URL
    let stateURL: URL
    let fileSystem = MemoryServiceFileSystem()
    let runner: FakeServiceCommandRunner
    let now = ISO8601DateFormatter().date(from: "2026-07-17T00:00:10Z")!

    init(loaded: Bool = false, printPIDs: [Int32] = []) throws {
        appURL = root.appendingPathComponent("Applications/Mac Face Lock.app")
        supportURL = root.appendingPathComponent("Library/Application Support/Mac Face Lock")
        launchAgentsURL = root.appendingPathComponent("Library/LaunchAgents")
        plistURL = launchAgentsURL.appendingPathComponent(
            "com.wuyi.mac-face-lock-background.plist"
        )
        backgroundPlistURL = plistURL
        legacyPlistURL = launchAgentsURL.appendingPathComponent(
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
        pollAttempts: Int = 3,
        pollIntervalNanoseconds: UInt64 = 0,
        stableHealthTimeout: TimeInterval = 300,
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
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
            healthPollIntervalNanoseconds: pollIntervalNanoseconds,
            stableHealthTimeout: stableHealthTimeout,
            heartbeatMaxAge: 5,
            now: { now },
            monotonicNow: monotonicNow,
            sleep: sleep
        )
    }

    func seedHealthyState(
        pid: Int32 = 42,
        camera: Bool = true,
        inputMonitoring: Bool = true,
        accessibility: Bool = true,
        heartbeatSequence: UInt64 = 1,
        heartbeatTimestamp: String = "2026-07-17T00:00:09Z"
    ) throws {
        let object: [String: Any] = [
            "status": "paused",
            "armed": false,
            "agent_pid": Int(pid),
            "camera_ready": camera,
            "input_monitoring_ready": inputMonitoring,
            "accessibility_ready": accessibility,
            "heartbeat_sequence": heartbeatSequence,
            "heartbeat_timestamp": heartbeatTimestamp,
        ]
        fileSystem.seed(
            try JSONSerialization.data(withJSONObject: object),
            at: stateURL
        )
    }

    func seedHealthyStateSequence(
        pid: Int32 = 42,
        sequences: [UInt64],
        timestamp: String = "2026-07-17T00:00:09Z",
        camera: Bool = true,
        inputMonitoring: Bool = true,
        accessibility: Bool = true
    ) throws {
        let data = try sequences.map { sequence in
            try JSONSerialization.data(
                withJSONObject: [
                    "status": "paused",
                    "armed": false,
                    "agent_pid": Int(pid),
                    "camera_ready": camera,
                    "input_monitoring_ready": inputMonitoring,
                    "accessibility_ready": accessibility,
                    "heartbeat_sequence": sequence,
                    "heartbeat_timestamp": timestamp,
                ] as [String: Any]
            )
        }
        fileSystem.seedReadSequence(data, at: stateURL)
    }

    static func templateData() throws -> Data {
        let object: [String: Any] = [
            "Label": "com.wuyi.mac-face-lock-background",
            "ProgramArguments": [
                "__APP_URL__/Contents/MacOS/MacFaceLock",
                "--internal-runtime",
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
            "ProcessType": "Background",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
    }

    static func backgroundTemplateData() throws -> Data {
        let object: [String: Any] = [
            "Label": "com.wuyi.mac-face-lock-background",
            "ProgramArguments": [
                "__APP_URL__/Contents/MacOS/MacFaceLock",
                "--internal-runtime",
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
            "ProcessType": "Background",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
    }

    static func legacyReleaseTemplateData() throws -> Data {
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
            "ProcessType": "Background",
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
        try await testLegacyRecognitionRejectsIntegerBooleanConfusion()
        try await testStatusRejectsDuplicatePlistKeysBeforeDictionaryCoercion()
        try await testStatusRejectsCDATAEncodedDuplicatePlistKey()
        try await testStatusAcceptsBinaryPlistWithoutDetectableXMLStructure()
        try await testLegacyDuplicateKeysBlockBeforeMutation()
        try await testLegacyCDATAEncodedDuplicateKeyBlocksBeforeMutation()
        try await testStatusRequiresCompleteRenderedBackgroundPlist()
        try await testResponsiveCurrentServiceCannotBypassUnknownLegacy()
        try await testResponsiveCurrentServiceCleansRecognizedLegacy()
        try await testResponsiveLegacyCleanupFailureRestoresBytesAndLoadedScope()
        try await testUnknownLegacyReleaseBlocksBeforeServiceMutation()
        try await testDirectoryFailuresCannotLeaveProtectionEnabled()
        try await testMissingControlDirectoryFailureRemainsFailOpen()
        try testProductionHealthWindowCoversPermissionAndHeartbeatStartup()
        try await testInstallReadsOnlyCurrentManagedFiles()
        try await testStatusReadsOnlyCurrentManagedFiles()
        try await testRestartReadsNoFiles()
        try await testInstallBootstrapDoesNotKickstart()
        try await testLoadedRollbackBootstrapDoesNotKickstart()
        try await testUninstallReadsNoFiles()
        try await testInstallRendersOnlyApplicationAndSupportPaths()
        try await testFailedBackgroundStartupPreservesLegacyBytesAndProtectionOff()
        try await testReplacementWaitsForBackgroundJobToDisappearBeforeBootstrap()
        try await testRecognizedLegacyReleaseMigratesAfterNewServiceResponds()
        try await testResponsiveMatchingInstallIsIdempotent()
        try await testFailedStableHealthRestoresPreviousPlistAndJob()
        try await testUninstallPreservesApplicationData()
        try await testUninstallPreservesPlistWhenAbsenceCannotBeProven()
        try await testUninstallWaitsForAuthoritativeJobAbsence()
        try await testUninstallDoesNotHideRunningJobRemovalFailure()
        try await testAgentPermissionFailureCannotReportHealthy()
        try await testStableInstallAllowsPendingPermissions()
        try await testStaleOrMissingHeartbeatCannotReportHealthy()
        try await testStableInstallRequiresAdvancingHeartbeat()
        try await testStableInstallWaitsThroughDuplicateHeartbeatPolls()
        try await testSlowHealthProbeCannotExceedTotalDeadline()
        try await testPriorJobPrintTimeoutAbortsBeforeAnyMutation()
        try await testPriorJobUnexpectedPrintFailureAbortsBeforeAnyMutation()
        try await testMovedApplicationNeedsRepair()
        print("Service manager tests passed")
    }

    private static func testDirectoryFailuresCannotLeaveProtectionEnabled() async throws {
        for directoryName in ["launch agents", "data", "logs"] {
            let fixture = try ServiceFixture()
            let controlURL = fixture.supportURL.appendingPathComponent(
                "data/control.json"
            )
            fixture.fileSystem.seed(
                try JSONSerialization.data(
                    withJSONObject: [
                        "schema_version": 1,
                        "protection_enabled": true,
                    ]
                ),
                at: controlURL
            )
            let failureURL: URL
            switch directoryName {
            case "launch agents":
                failureURL = fixture.launchAgentsURL
            case "data":
                failureURL = fixture.supportURL.appendingPathComponent(
                    "data",
                    isDirectory: true
                )
            default:
                failureURL = fixture.supportURL.appendingPathComponent(
                    "logs",
                    isDirectory: true
                )
            }
            fixture.fileSystem.failCreateDirectory(at: failureURL)

            do {
                try await fixture.manager().install(
                    appURL: fixture.appURL,
                    supportURL: fixture.supportURL
                )
                throw TestFailure.assertion(
                    "\(directoryName) creation failure unexpectedly installed service"
                )
            } catch is InjectedFileSystemError {
                // Expected.
            }

            let control = try JSONSerialization.jsonObject(
                with: fixture.fileSystem.readData(at: controlURL)
            ) as? [String: Any]
            try require(
                control?["protection_enabled"] as? Bool == false,
                "\(directoryName) creation failure left protection enabled"
            )
            try require(
                fixture.runner.calls.allSatisfy {
                    !["bootout", "bootstrap", "enable", "kickstart"]
                        .contains($0.arguments.first)
                },
                "\(directoryName) creation failure mutated launchd"
            )
        }
    }

    private static func testMissingControlDirectoryFailureRemainsFailOpen() async throws {
        let fixture = try ServiceFixture()
        let dataDirectoryURL = fixture.supportURL.appendingPathComponent(
            "data",
            isDirectory: true
        )
        let controlURL = dataDirectoryURL.appendingPathComponent("control.json")
        fixture.fileSystem.failCreateDirectory(at: dataDirectoryURL)

        do {
            try await fixture.manager().install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion(
                "missing control directory failure unexpectedly installed service"
            )
        } catch is InjectedFileSystemError {
            // Expected.
        }

        try require(
            !fixture.fileSystem.fileExists(at: controlURL),
            "missing control directory failure created an enabled control state"
        )
        try require(
            fixture.fileSystem.operations == [
                "mkdir:\(dataDirectoryURL.standardizedFileURL.path)",
            ],
            "missing control directory failure performed unrelated mutation"
        )
        try require(
            fixture.runner.calls.isEmpty,
            "missing control directory failure reached launchctl"
        )
    }

    private static func testResponsiveCurrentServiceCleansRecognizedLegacy() async throws {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42, 42])
        let backgroundTarget = "gui/501/com.wuyi.mac-face-lock-background"
        let legacyTarget = "gui/501/com.wuyi.mac-face-lock-agent"
        fixture.runner.seedLoadedTarget(legacyTarget, printPIDs: [99])
        let backgroundData = try renderTemplate(
            try ServiceFixture.backgroundTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(backgroundData, at: fixture.backgroundPlistURL)
        let legacyData = try renderTemplate(
            try ServiceFixture.legacyReleaseTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(legacyData, at: fixture.legacyPlistURL)
        try fixture.seedHealthyState(heartbeatSequence: 7)

        try await fixture.manager().install(
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )

        try require(
            !fixture.fileSystem.fileExists(at: fixture.legacyPlistURL),
            "responsive current service left the recognized legacy plist"
        )
        let mutationCalls = fixture.runner.calls.map(\.arguments).filter {
            ["bootout", "bootstrap", "enable", "kickstart"].contains($0.first)
        }
        try require(
            mutationCalls == [["bootout", legacyTarget]],
            "responsive current service did not limit mutation to legacy cleanup"
        )
        try require(
            !mutationCalls.contains(["bootout", backgroundTarget]),
            "responsive current service was replaced during legacy cleanup"
        )
        let status = await fixture.manager().status()
        try require(
            status.isResponsive && status.pid == 42,
            "legacy cleanup did not preserve responsive PID 42"
        )
    }

    private static func testStatusRejectsDuplicatePlistKeysBeforeDictionaryCoercion()
        async throws
    {
        let seedFixture = try ServiceFixture()
        let rendered = try renderTemplate(
            try ServiceFixture.backgroundTemplateData(),
            appURL: seedFixture.appURL,
            supportURL: seedFixture.supportURL
        )
        let argumentsXML = "<array>"
            + [
                seedFixture.appURL.appendingPathComponent(
                    "Contents/MacOS/MacFaceLock"
                ).path,
                "--internal-runtime",
                "--resources-dir",
                seedFixture.appURL.appendingPathComponent(
                    "Contents/Resources"
                ).path,
                "--support-dir",
                seedFixture.supportURL.path,
                "agent",
            ].map { "<string>\($0)</string>" }.joined()
            + "</array>"
        for (name, valueXML) in [
            ("ProgramArguments", argumentsXML),
            ("Label", "<string>com.wuyi.mac-face-lock-background</string>"),
        ] {
            let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
            fixture.fileSystem.seed(
                try plistDataWithDuplicateEntry(
                    rendered,
                    key: name,
                    valueXML: valueXML
                ),
                at: fixture.backgroundPlistURL
            )
            try fixture.seedHealthyState()

            let status = await fixture.manager().status()

            try require(
                status.state == .needsRepair,
                "status accepted duplicate (name) plist key"
            )
            try require(
                fixture.runner.calls.isEmpty,
                "duplicate (name) key reached launchctl before rejection"
            )
        }
    }

    private static func testLegacyDuplicateKeysBlockBeforeMutation() async throws {
        let seedFixture = try ServiceFixture()
        let rendered = try renderTemplate(
            try ServiceFixture.legacyReleaseTemplateData(),
            appURL: seedFixture.appURL,
            supportURL: seedFixture.supportURL
        )
        let argumentsXML = "<array>"
            + [
                seedFixture.appURL.appendingPathComponent(
                    "Contents/Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
                ).path,
                "--resources-dir",
                seedFixture.appURL.appendingPathComponent(
                    "Contents/Resources"
                ).path,
                "--support-dir",
                seedFixture.supportURL.path,
                "agent",
            ].map { "<string>\($0)</string>" }.joined()
            + "</array>"
        for (name, valueXML) in [
            ("ProgramArguments", argumentsXML),
            ("Label", "<string>com.wuyi.mac-face-lock-agent</string>"),
        ] {
            let fixture = try ServiceFixture(printPIDs: [99, 42, 42, 42])
            let duplicateData = try plistDataWithDuplicateEntry(
                rendered,
                key: name,
                valueXML: valueXML
            )
            fixture.fileSystem.seed(duplicateData, at: fixture.legacyPlistURL)

            do {
                try await fixture.manager().install(
                    appURL: fixture.appURL,
                    supportURL: fixture.supportURL
                )
                throw TestFailure.assertion(
                    "duplicate (name) legacy key did not block migration"
                )
            } catch ServiceManagerError.invalidTemplate {
                // Expected.
            }

            let retainedLegacyData = try fixture.fileSystem.readData(
                at: fixture.legacyPlistURL
            )
            try require(
                retainedLegacyData == duplicateData,
                "duplicate (name) legacy key changed plist bytes"
            )
            try require(
                fixture.runner.calls.allSatisfy {
                    !["bootout", "bootstrap", "enable", "kickstart"]
                        .contains($0.arguments.first)
                },
                "duplicate (name) legacy key mutated launchd"
            )
            try require(
                !fixture.fileSystem.fileExists(at: fixture.backgroundPlistURL),
                "duplicate (name) legacy key wrote background plist"
            )
        }
    }

    private static func testStatusRejectsCDATAEncodedDuplicatePlistKey()
        async throws
    {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
        let rendered = try renderTemplate(
            try ServiceFixture.backgroundTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        let argumentsXML = "<array>"
            + [
                fixture.appURL.appendingPathComponent(
                    "Contents/MacOS/MacFaceLock"
                ).path,
                "--internal-runtime",
                "--resources-dir",
                fixture.appURL.appendingPathComponent(
                    "Contents/Resources"
                ).path,
                "--support-dir",
                fixture.supportURL.path,
                "agent",
            ].map { "<string>\($0)</string>" }.joined()
            + "</array>"
        fixture.fileSystem.seed(
            try plistDataWithCDATAKeyBeforeExistingEntry(
                rendered,
                key: "ProgramArguments",
                valueXML: argumentsXML
            ),
            at: fixture.backgroundPlistURL
        )
        try fixture.seedHealthyState()

        let status = await fixture.manager().status()

        try require(
            status.state == .needsRepair,
            "status accepted CDATA-encoded duplicate plist key"
        )
        try require(
            fixture.runner.calls.isEmpty,
            "CDATA-encoded duplicate key reached launchctl before rejection"
        )
    }

    private static func testLegacyCDATAEncodedDuplicateKeyBlocksBeforeMutation()
        async throws
    {
        let fixture = try ServiceFixture(printPIDs: [99, 42, 42, 42])
        let rendered = try renderTemplate(
            try ServiceFixture.legacyReleaseTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        let argumentsXML = "<array>"
            + [
                fixture.appURL.appendingPathComponent(
                    "Contents/Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
                ).path,
                "--resources-dir",
                fixture.appURL.appendingPathComponent(
                    "Contents/Resources"
                ).path,
                "--support-dir",
                fixture.supportURL.path,
                "agent",
            ].map { "<string>\($0)</string>" }.joined()
            + "</array>"
        let duplicateData = try plistDataWithCDATAKeyBeforeExistingEntry(
            rendered,
            key: "ProgramArguments",
            valueXML: argumentsXML
        )
        fixture.fileSystem.seed(duplicateData, at: fixture.legacyPlistURL)

        do {
            try await fixture.manager().install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion(
                "CDATA-encoded duplicate legacy key did not block migration"
            )
        } catch ServiceManagerError.invalidTemplate {
            // Expected.
        }

        let retainedLegacyData = try fixture.fileSystem.readData(
            at: fixture.legacyPlistURL
        )
        try require(
            retainedLegacyData == duplicateData,
            "CDATA-encoded duplicate legacy key changed plist bytes"
        )
        try require(
            fixture.runner.calls.allSatisfy {
                !["bootout", "bootstrap", "enable", "kickstart"]
                    .contains($0.arguments.first)
            },
            "CDATA-encoded duplicate legacy key mutated launchd"
        )
        try require(
            !fixture.fileSystem.fileExists(at: fixture.backgroundPlistURL),
            "CDATA-encoded duplicate legacy key wrote background plist"
        )
    }

    private static func testStatusAcceptsBinaryPlistWithoutDetectableXMLStructure()
        async throws
    {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
        let rendered = try renderTemplate(
            try ServiceFixture.backgroundTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        let binaryData = try PropertyListSerialization.data(
            fromPropertyList: try requireDictionary(rendered),
            format: .binary,
            options: 0
        )
        fixture.fileSystem.seed(binaryData, at: fixture.backgroundPlistURL)
        try fixture.seedHealthyState()

        let status = await fixture.manager().status()

        try require(
            status.state == .healthy,
            "binary plist was rejected without duplicate-key evidence"
        )
    }

    private static func testResponsiveLegacyCleanupFailureRestoresBytesAndLoadedScope() async throws {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
        let legacyTarget = "gui/501/com.wuyi.mac-face-lock-agent"
        fixture.runner.seedLoadedTarget(legacyTarget, printPIDs: [99])
        let backgroundData = try renderTemplate(
            try ServiceFixture.backgroundTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(backgroundData, at: fixture.backgroundPlistURL)
        let legacyData = try renderTemplate(
            try ServiceFixture.legacyReleaseTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(legacyData, at: fixture.legacyPlistURL)
        fixture.fileSystem.failRemoveItem(at: fixture.legacyPlistURL)
        try fixture.seedHealthyState(heartbeatSequence: 7)

        do {
            try await fixture.manager().install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion(
                "legacy cleanup removal failure unexpectedly succeeded"
            )
        } catch is InjectedFileSystemError {
            // Expected.
        }

        let retainedLegacyData = try fixture.fileSystem.readData(
            at: fixture.legacyPlistURL
        )
        try require(
            retainedLegacyData == legacyData,
            "responsive cleanup failure changed legacy plist bytes"
        )
        try require(
            fixture.runner.calls.contains {
                $0.arguments == [
                    "bootstrap",
                    "gui/501",
                    fixture.legacyPlistURL.standardizedFileURL.path,
                ]
            },
            "responsive cleanup failure did not reload the prior legacy job"
        )
        try require(
            !fixture.runner.calls.contains {
                $0.arguments == [
                    "bootstrap",
                    "gui/501",
                    fixture.backgroundPlistURL.standardizedFileURL.path,
                ]
            },
            "responsive cleanup failure replaced the healthy current job"
        )
        let controlURL = fixture.supportURL.appendingPathComponent(
            "data/control.json"
        )
        let control = try JSONSerialization.jsonObject(
            with: fixture.fileSystem.readData(at: controlURL)
        ) as? [String: Any]
        try require(
            control?["protection_enabled"] as? Bool == false,
            "responsive cleanup failure restored protection true"
        )
    }

    private static func testResponsiveCurrentServiceCannotBypassUnknownLegacy() async throws {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
        let backgroundData = try renderTemplate(
            try ServiceFixture.backgroundTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(backgroundData, at: fixture.backgroundPlistURL)
        let recognizedLegacyData = try renderTemplate(
            try ServiceFixture.legacyReleaseTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        var unknownLegacy = try requireDictionary(recognizedLegacyData)
        unknownLegacy["UnexpectedManagedKey"] = true
        let unknownLegacyData = try PropertyListSerialization.data(
            fromPropertyList: unknownLegacy,
            format: .xml,
            options: 0
        )
        fixture.fileSystem.seed(unknownLegacyData, at: fixture.legacyPlistURL)
        try fixture.seedHealthyState(heartbeatSequence: 7)
        let controlURL = fixture.supportURL.appendingPathComponent(
            "data/control.json"
        )
        fixture.fileSystem.seed(
            try JSONSerialization.data(
                withJSONObject: [
                    "schema_version": 1,
                    "protection_enabled": true,
                ]
            ),
            at: controlURL
        )

        do {
            try await fixture.manager().install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion(
                "responsive current service bypassed unknown legacy bytes"
            )
        } catch ServiceManagerError.invalidTemplate {
            // Expected.
        }

        let retainedLegacyData = try fixture.fileSystem.readData(
            at: fixture.legacyPlistURL
        )
        try require(
            retainedLegacyData == unknownLegacyData,
            "responsive current service changed unknown legacy bytes"
        )
        try require(
            fixture.runner.calls.allSatisfy {
                !["bootout", "bootstrap", "enable", "kickstart"]
                    .contains($0.arguments.first)
            },
            "responsive current service mutated launchd before unknown legacy block"
        )
        try require(
            fixture.fileSystem.operations == [
                "write:\(controlURL.standardizedFileURL.path)",
            ],
            "responsive unknown legacy path performed unrelated filesystem mutation"
        )
    }

    private static func testStatusRequiresCompleteRenderedBackgroundPlist() async throws {
        let seedFixture = try ServiceFixture()
        let renderedData = try renderTemplate(
            try ServiceFixture.backgroundTemplateData(),
            appURL: seedFixture.appURL,
            supportURL: seedFixture.supportURL
        )
        let rendered = try requireDictionary(renderedData)

        func changed(
            _ name: String,
            key: String,
            value: Any
        ) -> (String, [String: Any]) {
            var dictionary = rendered
            dictionary[key] = value
            return (name, dictionary)
        }

        var extraKey = rendered
        extraKey["UnexpectedManagedKey"] = true
        let variants: [(String, [String: Any])] = [
            changed(
                "working directory",
                key: "WorkingDirectory",
                value: "/unexpected/working-directory"
            ),
            changed(
                "stdout path",
                key: "StandardOutPath",
                value: "/unexpected/stdout.log"
            ),
            changed(
                "stderr path",
                key: "StandardErrorPath",
                value: "/unexpected/stderr.log"
            ),
            changed("RunAtLoad", key: "RunAtLoad", value: false),
            changed("KeepAlive", key: "KeepAlive", value: false),
            changed(
                "process type",
                key: "ProcessType",
                value: "Interactive"
            ),
            ("extra key", extraKey),
        ]

        for (variant, dictionary) in variants {
            let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
            fixture.fileSystem.seed(
                try PropertyListSerialization.data(
                    fromPropertyList: dictionary,
                    format: .xml,
                    options: 0
                ),
                at: fixture.backgroundPlistURL
            )
            try fixture.seedHealthyState()

            let status = await fixture.manager().status()

            try require(
                status.state == .needsRepair,
                "status accepted altered \(variant) in background plist"
            )
            try require(
                fixture.runner.calls.isEmpty,
                "status trusted launchd before validating altered \(variant)"
            )
        }
    }

    private static func testLegacyRecognitionRejectsIntegerBooleanConfusion() async throws {
        let seedFixture = try ServiceFixture()
        let recognizedData = try renderTemplate(
            try ServiceFixture.legacyReleaseTemplateData(),
            appURL: seedFixture.appURL,
            supportURL: seedFixture.supportURL
        )
        let recognized = try requireDictionary(recognizedData)

        for key in ["RunAtLoad", "KeepAlive"] {
            let fixture = try ServiceFixture(printPIDs: [42, 42, 42])
            var confused = recognized
            confused[key] = 1
            let confusedData = try PropertyListSerialization.data(
                fromPropertyList: confused,
                format: .xml,
                options: 0
            )
            fixture.fileSystem.seed(confusedData, at: fixture.legacyPlistURL)
            try fixture.seedHealthyStateSequence(sequences: [1, 2, 3])

            do {
                try await fixture.manager().install(
                    appURL: fixture.appURL,
                    supportURL: fixture.supportURL
                )
                throw TestFailure.assertion(
                    "legacy recognition accepted integer \(key) as Boolean"
                )
            } catch ServiceManagerError.invalidTemplate {
                // Expected.
            }

            let retainedData = try fixture.fileSystem.readData(
                at: fixture.legacyPlistURL
            )
            try require(
                retainedData == confusedData,
                "integer \(key) confusion changed legacy bytes"
            )
            try require(
                !fixture.fileSystem.fileExists(at: fixture.backgroundPlistURL),
                "integer \(key) confusion wrote the background plist"
            )
            try require(
                fixture.runner.calls.allSatisfy {
                    !["bootout", "bootstrap", "enable", "kickstart"]
                        .contains($0.arguments.first)
                },
                "integer \(key) confusion mutated launchd"
            )
        }
    }

    private static func testProductionHealthWindowCoversPermissionAndHeartbeatStartup() throws {
        let agentStartupBudgetSeconds = 5.0 + 5.0 + (3.0 * 1.0)
        try require(
            ServiceManager.productionHealthPollIntervalNanoseconds == 1_000_000_000,
            "production health polling cadence is not one second"
        )
        try require(
            ServiceManager.productionStableHealthWindowSeconds >= 300,
            "production stable-health window is shorter than five minutes"
        )
        try require(
            ServiceManager.productionStableHealthWindowSeconds
                > agentStartupBudgetSeconds,
            "production stable-health window does not cover permission waits and heartbeats"
        )
    }

    private static func testInstallReadsOnlyCurrentManagedFiles() async throws {
        let fixture = try ServiceFixture(printPIDs: [42, 42, 42])
        try fixture.seedHealthyStateSequence(sequences: [1, 2, 3])

        try await fixture.manager().install(
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )

        try requireReadBoundary(
            fixture,
            operation: "install",
            allowedReadPaths: [
                fixture.templateURL.standardizedFileURL.path,
                fixture.plistURL.standardizedFileURL.path,
                fixture.stateURL.standardizedFileURL.path,
            ]
        )
    }

    private static func testStatusReadsOnlyCurrentManagedFiles() async throws {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
        try seedInstalledReleaseAgent(in: fixture)
        try fixture.seedHealthyState()

        let status = await fixture.manager().status()

        try require(status.isHealthy, "current background service did not report healthy")
        try requireReadBoundary(
            fixture,
            operation: "status",
            allowedReadPaths: [
                fixture.templateURL.standardizedFileURL.path,
                fixture.plistURL.standardizedFileURL.path,
                fixture.stateURL.standardizedFileURL.path,
            ]
        )
    }

    private static func testRestartReadsNoFiles() async throws {
        let fixture = try ServiceFixture()

        try await fixture.manager().restart()

        try require(
            fixture.runner.calls.map(\.arguments) == [
                ["enable", "gui/501/com.wuyi.mac-face-lock-background"],
                ["kickstart", "-k", "gui/501/com.wuyi.mac-face-lock-background"],
            ],
            "explicit restart did not preserve enable followed by kickstart"
        )
        try requireReadBoundary(
            fixture,
            operation: "restart",
            allowedReadPaths: []
        )
    }

    private static func testInstallBootstrapDoesNotKickstart() async throws {
        let fixture = try ServiceFixture(printPIDs: [42, 42, 42])
        try fixture.seedHealthyStateSequence(sequences: [1, 2, 3])

        try await fixture.manager().install(
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )

        let mutationCalls = fixture.runner.calls.map(\.arguments).filter {
            ["bootout", "bootstrap", "enable", "kickstart"].contains($0.first)
        }
        try require(
            mutationCalls == [
                [
                    "bootstrap",
                    "gui/501",
                    fixture.plistURL.standardizedFileURL.path,
                ],
                ["enable", "gui/501/com.wuyi.mac-face-lock-background"],
            ],
            "successful install kickstarted a RunAtLoad job after bootstrap"
        )
    }

    private static func testLoadedRollbackBootstrapDoesNotKickstart() async throws {
        let fixture = try ServiceFixture(
            loaded: true,
            printPIDs: [99, 41, 42, 42]
        )
        let previous: [String: Any] = [
            "Label": "com.wuyi.mac-face-lock-background",
            "ProgramArguments": ["/previous/MacFaceLockAgent", "/previous/project"],
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        fixture.fileSystem.seed(
            try PropertyListSerialization.data(
                fromPropertyList: previous,
                format: .xml,
                options: 0
            ),
            at: fixture.plistURL
        )
        try fixture.seedHealthyStateSequence(pid: 42, sequences: [1, 2, 3])

        do {
            try await fixture.manager(pollAttempts: 3).install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion("unstable service install unexpectedly succeeded")
        } catch is ServiceManagerError {
            // Expected.
        }

        let mutationCalls = fixture.runner.calls.map(\.arguments).filter {
            ["bootout", "bootstrap", "enable", "kickstart"].contains($0.first)
        }
        try require(
            Array(mutationCalls.suffix(3)) == [
                ["bootout", "gui/501/com.wuyi.mac-face-lock-background"],
                [
                    "bootstrap",
                    "gui/501",
                    fixture.plistURL.standardizedFileURL.path,
                ],
                ["enable", "gui/501/com.wuyi.mac-face-lock-background"],
            ],
            "loaded rollback kickstarted a RunAtLoad job after bootstrap"
        )
    }

    private static func testUninstallReadsNoFiles() async throws {
        let fixture = try ServiceFixture(loaded: true)
        fixture.fileSystem.seed(Data("current plist".utf8), at: fixture.plistURL)

        _ = try await fixture.manager().uninstallPreservingData()

        try requireReadBoundary(
            fixture,
            operation: "uninstall",
            allowedReadPaths: []
        )
    }

    private static func seedInstalledReleaseAgent(
        in fixture: ServiceFixture
    ) throws {
        let rendered = try renderTemplate(
            try ServiceFixture.templateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(rendered, at: fixture.plistURL)
    }

    private static func requireReadBoundary(
        _ fixture: ServiceFixture,
        operation: String,
        allowedReadPaths: Set<String>
    ) throws {
        let actualReadPaths = Set(fixture.fileSystem.readPaths)
        try require(
            actualReadPaths == allowedReadPaths,
            "\(operation) read outside current managed files: "
                + actualReadPaths.sorted().joined(separator: ", ")
        )

        let legacyStatusPlist = fixture.launchAgentsURL.appendingPathComponent(
            "com.wuyi.mac-face-lock-status.plist"
        ).standardizedFileURL.path
        try require(
            !actualReadPaths.contains(legacyStatusPlist),
            "\(operation) read the legacy status LaunchAgent plist"
        )
        let launchAgentsPrefix = fixture.launchAgentsURL.standardizedFileURL.path + "/"
        let launchAgentReadPaths = actualReadPaths.filter {
            $0.hasPrefix(launchAgentsPrefix)
        }
        let allowedLaunchAgentReadPaths = allowedReadPaths.filter {
            $0.hasPrefix(launchAgentsPrefix)
        }
        try require(
            launchAgentReadPaths == allowedLaunchAgentReadPaths,
            "\(operation) read an extra LaunchAgents file"
        )
        try require(
            launchAgentReadPaths.isSubset(
                of: [fixture.plistURL.standardizedFileURL.path]
            ),
            "\(operation) read a non-current LaunchAgents plist"
        )
    }

    private static func testInstallRendersOnlyApplicationAndSupportPaths() async throws {
        let fixture = try ServiceFixture(printPIDs: [42, 42, 42])
        try fixture.seedHealthyStateSequence(sequences: [1, 2, 3])

        try await fixture.manager().install(
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )

        let plistData = try fixture.fileSystem.readData(at: fixture.plistURL)
        let plist = try requireDictionary(plistData)
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let expectedProgram = fixture.appURL.appendingPathComponent(
            "Contents/MacOS/MacFaceLock"
        ).path
        try require(arguments.first == expectedProgram, "main application path was not embedded")
        try require(
            arguments == [
                expectedProgram,
                "--internal-runtime",
                "--resources-dir",
                fixture.appURL.appendingPathComponent("Contents/Resources").path,
                "--support-dir",
                fixture.supportURL.path,
                "agent",
            ],
            "release background arguments did not use the internal runtime contract"
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

    private static func testResponsiveMatchingInstallIsIdempotent() async throws {
        let fixture = try ServiceFixture(
            loaded: true,
            printPIDs: [42, 42, 42, 42, 42]
        )
        let rendered = try renderTemplate(
            try ServiceFixture.backgroundTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(rendered, at: fixture.backgroundPlistURL)
        try fixture.seedHealthyStateSequence(sequences: [7, 8, 9, 10])

        try await fixture.manager().install(
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )

        let mutationCalls = fixture.runner.calls.map(\.arguments).filter {
            ["bootout", "bootstrap", "enable", "kickstart"].contains($0.first)
        }
        try require(
            mutationCalls.isEmpty,
            "responsive matching background service was unnecessarily replaced"
        )
        try require(fixture.runner.loaded, "idempotent install stopped the loaded service")
        let status = await fixture.manager().status()
        try require(status.pid == 42, "idempotent install did not retain PID 42")
        let controlURL = fixture.supportURL.appendingPathComponent("data/control.json")
        let control = try JSONSerialization.jsonObject(
            with: fixture.fileSystem.readData(at: controlURL)
        ) as? [String: Any]
        try require(
            control?["protection_enabled"] as? Bool == false,
            "idempotent install did not keep protection disabled"
        )
    }

    private static func testRecognizedLegacyReleaseMigratesAfterNewServiceResponds() async throws {
        let fixture = try ServiceFixture()
        let legacyTarget = "gui/501/com.wuyi.mac-face-lock-agent"
        let backgroundTarget = "gui/501/com.wuyi.mac-face-lock-background"
        fixture.runner.seedLoadedTarget(legacyTarget, printPIDs: [99])
        fixture.runner.seedUnloadedTarget(
            backgroundTarget,
            printPIDs: [42, 42, 42]
        )
        let legacyData = try renderTemplate(
            try ServiceFixture.legacyReleaseTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(legacyData, at: fixture.legacyPlistURL)
        try fixture.seedHealthyStateSequence(sequences: [1, 2, 3])
        var responsivePrintsWhenLegacyRemoved: Int?
        fixture.fileSystem.onRemove = { removedURL in
            guard removedURL == fixture.legacyPlistURL.standardizedFileURL,
                  let bootstrapIndex = fixture.runner.calls.lastIndex(where: {
                      $0.arguments == [
                          "bootstrap",
                          "gui/501",
                          fixture.backgroundPlistURL.standardizedFileURL.path,
                      ]
                  }) else {
                return
            }
            responsivePrintsWhenLegacyRemoved = fixture.runner.calls[
                (bootstrapIndex + 1)...
            ].filter {
                $0.arguments == ["print", backgroundTarget]
            }.count
        }

        try await fixture.manager().install(
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )

        try require(
            !fixture.fileSystem.fileExists(at: fixture.legacyPlistURL),
            "recognized legacy release plist was not removed"
        )
        let backgroundPrints = fixture.runner.calls.filter {
            $0.arguments == ["print", backgroundTarget]
        }
        try require(
            backgroundPrints.count >= 3
                && responsivePrintsWhenLegacyRemoved == 3,
            "legacy plist was removed before the new service proved responsive"
        )
        let mutations = fixture.runner.calls.map(\.arguments).filter {
            ["bootout", "bootstrap", "enable", "kickstart"].contains($0.first)
        }
        try require(
            mutations.contains(["bootout", legacyTarget]),
            "recognized legacy release service was not stopped"
        )
        try require(
            fixture.fileSystem.fileExists(at: fixture.backgroundPlistURL),
            "recognized legacy release did not install the background plist"
        )
    }

    private static func testUnknownLegacyReleaseBlocksBeforeServiceMutation() async throws {
        let seedFixture = try ServiceFixture()
        let recognizedData = try renderTemplate(
            try ServiceFixture.legacyReleaseTemplateData(),
            appURL: seedFixture.appURL,
            supportURL: seedFixture.supportURL
        )
        let recognizedObject = try requireDictionary(recognizedData)
        var extraKeyObject = recognizedObject
        extraKeyObject["UnexpectedManagedKey"] = true
        var wrongArgumentsObject = recognizedObject
        var wrongArguments = wrongArgumentsObject["ProgramArguments"] as? [String] ?? []
        wrongArguments[0] = "/unknown/background-service"
        wrongArgumentsObject["ProgramArguments"] = wrongArguments
        var renamedArgumentsObject = recognizedObject
        let renamedArguments = renamedArgumentsObject.removeValue(
            forKey: "ProgramArguments"
        )
        renamedArgumentsObject["program_arguments"] = renamedArguments

        for (variant, unknownObject) in [
            ("extra key", extraKeyObject),
            ("wrong arguments", wrongArgumentsObject),
            ("renamed arguments key", renamedArgumentsObject),
        ] {
            let fixture = try ServiceFixture(printPIDs: [42, 42, 42])
            let unknownData = try PropertyListSerialization.data(
                fromPropertyList: unknownObject,
                format: .xml,
                options: 0
            )
            fixture.fileSystem.seed(unknownData, at: fixture.legacyPlistURL)
            try fixture.seedHealthyStateSequence(sequences: [1, 2, 3])

            do {
                try await fixture.manager().install(
                    appURL: fixture.appURL,
                    supportURL: fixture.supportURL
                )
                throw TestFailure.assertion(
                    "\(variant) legacy release plist did not block migration"
                )
            } catch ServiceManagerError.invalidTemplate {
                // Expected.
            }

            try require(
                fixture.runner.calls.allSatisfy {
                    !["bootout", "bootstrap", "enable", "kickstart"]
                        .contains($0.arguments.first)
                },
                "\(variant) legacy release triggered launchctl mutation"
            )
            let retainedLegacyData = try fixture.fileSystem.readData(
                at: fixture.legacyPlistURL
            )
            try require(
                retainedLegacyData == unknownData,
                "\(variant) legacy release plist bytes were changed"
            )
            try require(
                !fixture.fileSystem.fileExists(at: fixture.backgroundPlistURL),
                "\(variant) legacy release wrote a background plist"
            )
            let controlURL = fixture.supportURL.appendingPathComponent(
                "data/control.json"
            )
            let control = try JSONSerialization.jsonObject(
                with: fixture.fileSystem.readData(at: controlURL)
            ) as? [String: Any]
            try require(
                control?["protection_enabled"] as? Bool == false,
                "\(variant) legacy release did not leave protection disabled"
            )
            let dataDirectoryURL = fixture.supportURL.appendingPathComponent(
                "data",
                isDirectory: true
            )
            try require(
                fixture.fileSystem.operations == [
                    "mkdir:\(dataDirectoryURL.standardizedFileURL.path)",
                    "write:\(controlURL.standardizedFileURL.path)",
                ],
                "\(variant) legacy release performed unrelated filesystem mutation"
            )
        }
    }

    private static func testReplacementWaitsForBackgroundJobToDisappearBeforeBootstrap() async throws {
        let fixture = try ServiceFixture()
        let backgroundTarget = "gui/501/com.wuyi.mac-face-lock-background"
        fixture.runner.seedLoadedTarget(
            backgroundTarget,
            printPIDs: [99, 99, 99, 42, 42, 42]
        )
        fixture.runner.delayBootout(
            of: backgroundTarget,
            loadedPrintsBeforeAbsent: 2
        )
        let movedAppURL = fixture.root.appendingPathComponent("Old/Mac Face Lock.app")
        let mismatchedData = try renderTemplate(
            try ServiceFixture.backgroundTemplateData(),
            appURL: movedAppURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(mismatchedData, at: fixture.backgroundPlistURL)
        try fixture.seedHealthyStateSequence(sequences: [1, 2, 3])

        try await fixture.manager().install(
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )

        let calls = fixture.runner.calls.map(\.arguments)
        guard let bootoutIndex = calls.firstIndex(
            of: ["bootout", backgroundTarget]
        ),
              let bootstrapIndex = calls.firstIndex(where: {
                  $0.first == "bootstrap"
              }) else {
            throw TestFailure.assertion(
                "background replacement did not boot out and bootstrap"
            )
        }
        let unloadProofCalls = calls[(bootoutIndex + 1)..<bootstrapIndex]
            .filter { $0 == ["print", backgroundTarget] }
        try require(
            unloadProofCalls.count == 3,
            "bootstrap did not wait for launchctl print to prove absence"
        )
        try require(
            !calls.contains(["kickstart", "-k", backgroundTarget]),
            "replacement kickstarted a RunAtLoad service"
        )
    }

    private static func testFailedBackgroundStartupPreservesLegacyBytesAndProtectionOff() async throws {
        let fixture = try ServiceFixture()
        let legacyTarget = "gui/501/com.wuyi.mac-face-lock-agent"
        let backgroundTarget = "gui/501/com.wuyi.mac-face-lock-background"
        fixture.runner.seedLoadedTarget(legacyTarget, printPIDs: [99])
        fixture.runner.seedUnloadedTarget(
            backgroundTarget,
            printPIDs: [0, 0, 0]
        )
        let legacyData = try renderTemplate(
            try ServiceFixture.legacyReleaseTemplateData(),
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )
        fixture.fileSystem.seed(legacyData, at: fixture.legacyPlistURL)
        try fixture.seedHealthyStateSequence(pid: 42, sequences: [1, 2, 3])

        do {
            try await fixture.manager().install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion(
                "unresponsive background service unexpectedly completed migration"
            )
        } catch ServiceManagerError.unstableService {
            // Expected.
        }

        let retainedLegacyData = try fixture.fileSystem.readData(
            at: fixture.legacyPlistURL
        )
        try require(
            retainedLegacyData == legacyData,
            "failed background startup did not preserve legacy plist bytes"
        )
        try require(
            !fixture.fileSystem.fileExists(at: fixture.backgroundPlistURL),
            "failed background startup retained the failed new plist"
        )
        try require(
            fixture.runner.calls.contains {
                $0.arguments == [
                    "bootstrap",
                    "gui/501",
                    fixture.backgroundPlistURL.standardizedFileURL.path,
                ]
            },
            "failure fixture did not exercise new background startup"
        )
        try require(
            fixture.runner.calls.contains {
                $0.arguments == [
                    "bootstrap",
                    "gui/501",
                    fixture.legacyPlistURL.standardizedFileURL.path,
                ]
            },
            "failed migration did not restore the previously loaded legacy service"
        )
        let controlURL = fixture.supportURL.appendingPathComponent("data/control.json")
        let control = try JSONSerialization.jsonObject(
            with: fixture.fileSystem.readData(at: controlURL)
        ) as? [String: Any]
        try require(
            control?["protection_enabled"] as? Bool == false,
            "failed background startup did not leave protection disabled"
        )
    }

    private static func testFailedStableHealthRestoresPreviousPlistAndJob() async throws {
        let fixture = try ServiceFixture(
            loaded: true,
            printPIDs: [99, 41, 42, 42]
        )
        let previous: [String: Any] = [
            "Label": "com.wuyi.mac-face-lock-background",
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
        try fixture.seedHealthyStateSequence(pid: 42, sequences: [1, 2, 3])

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

        _ = try await fixture.manager().uninstallPreservingData()

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

    private static func testUninstallWaitsForAuthoritativeJobAbsence() async throws {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42, 42, 42])
        let target = "gui/501/com.wuyi.mac-face-lock-background"
        fixture.runner.delayBootout(
            of: target,
            loadedPrintsBeforeAbsent: 2
        )
        fixture.fileSystem.seed(Data("plist".utf8), at: fixture.plistURL)
        var callsAtRemoval: [[String]] = []
        fixture.fileSystem.onRemove = { url in
            guard url.standardizedFileURL == fixture.plistURL.standardizedFileURL else {
                return
            }
            callsAtRemoval = fixture.runner.calls.map(\.arguments)
        }

        _ = try await fixture.manager(pollAttempts: 3).uninstallPreservingData()

        let absenceProofs = callsAtRemoval.filter {
            $0 == ["print", target]
        }
        try require(
            absenceProofs.count == 3,
            "uninstall removed its plist before launchctl proved job absence"
        )
        try require(
            !fixture.fileSystem.fileExists(at: fixture.plistURL),
            "authoritatively stopped service retained its plist"
        )
    }

    private static func testUninstallPreservesPlistWhenAbsenceCannotBeProven()
        async throws
    {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42, 42, 42])
        let target = "gui/501/com.wuyi.mac-face-lock-background"
        fixture.runner.delayBootout(
            of: target,
            loadedPrintsBeforeAbsent: 99
        )
        let plistData = Data("diagnosable plist".utf8)
        fixture.fileSystem.seed(plistData, at: fixture.plistURL)

        do {
            _ = try await fixture.manager(pollAttempts: 3).uninstallPreservingData()
            throw TestFailure.assertion(
                "uninstall succeeded without authoritative job absence"
            )
        } catch ServiceManagerError.unstableService {
            // Expected.
        }

        let retainedPlistData = try fixture.fileSystem.readData(
            at: fixture.plistURL
        )
        try require(
            retainedPlistData == plistData,
            "failed absence proof removed or changed the diagnosable plist"
        )
        try require(
            fixture.runner.calls.filter {
                $0.arguments == ["print", target]
            }.count == 3,
            "uninstall did not exhaust its bounded absence proof"
        )
    }

    private static func testUninstallDoesNotHideRunningJobRemovalFailure() async throws {
        let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
        fixture.runner.bootoutExitCode = 5
        fixture.fileSystem.seed(Data("plist".utf8), at: fixture.plistURL)

        do {
            _ = try await fixture.manager().uninstallPreservingData()
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

    private static func testStableInstallAllowsPendingPermissions() async throws {
        let fixture = try ServiceFixture(printPIDs: [42, 42, 42, 42])
        try fixture.seedHealthyStateSequence(
            sequences: [1, 2, 3],
            inputMonitoring: false,
            accessibility: false
        )

        try await fixture.manager().install(
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )

        let status = await fixture.manager().status()
        try require(
            fixture.fileSystem.fileExists(at: fixture.plistURL),
            "pending permissions rolled back a responsive Agent installation"
        )
        try require(status.isResponsive, "responsive Agent was not reported responsive")
        try require(!status.isHealthy, "pending Agent permissions reported protection ready")
        try require(status.cameraReady, "camera grant was lost")
        try require(!status.inputMonitoringReady, "input-monitoring denial was ignored")
        try require(!status.accessibilityReady, "accessibility denial was ignored")
        try require(fixture.runner.bootstrapCount == 1, "responsive install unexpectedly rolled back")
    }

    private static func testStaleOrMissingHeartbeatCannotReportHealthy() async throws {
        for (sequence, timestamp, label) in [
            (UInt64?.none, "2026-07-17T00:00:09Z", "missing sequence"),
            (UInt64?.some(7), "2026-07-16T23:59:00Z", "stale timestamp"),
        ] {
            let fixture = try ServiceFixture(loaded: true, printPIDs: [42])
            let rendered = try renderTemplate(
                try fixture.fileSystem.readData(at: fixture.templateURL),
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            fixture.fileSystem.seed(rendered, at: fixture.plistURL)
            var object: [String: Any] = [
                "status": "paused",
                "armed": false,
                "agent_pid": 42,
                "camera_ready": true,
                "input_monitoring_ready": true,
                "accessibility_ready": true,
                "heartbeat_timestamp": timestamp,
            ]
            if let sequence {
                object["heartbeat_sequence"] = sequence
            }
            fixture.fileSystem.seed(
                try JSONSerialization.data(withJSONObject: object),
                at: fixture.stateURL
            )

            let status = await fixture.manager().status()

            try require(
                status.state == .unhealthy,
                "\(label) Agent state reported healthy"
            )
        }
    }

    private static func testStableInstallRequiresAdvancingHeartbeat() async throws {
        let fixture = try ServiceFixture(printPIDs: [42, 42, 42])
        try fixture.seedHealthyStateSequence(sequences: [7, 7, 7])

        do {
            try await fixture.manager().install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion(
                "stable install accepted a non-advancing heartbeat sequence"
            )
        } catch is ServiceManagerError {
            // Expected.
        }

        try require(
            !fixture.fileSystem.fileExists(at: fixture.plistURL),
            "non-advancing heartbeat failure did not roll back the new plist"
        )
    }

    private static func testStableInstallWaitsThroughDuplicateHeartbeatPolls() async throws {
        let fixture = try ServiceFixture(printPIDs: [42, 42, 42, 42, 42])
        try fixture.seedHealthyStateSequence(sequences: [1, 1, 2, 2, 3])

        try await fixture.manager(pollAttempts: 5).install(
            appURL: fixture.appURL,
            supportURL: fixture.supportURL
        )

        try require(
            fixture.fileSystem.fileExists(at: fixture.plistURL),
            "stable install reset progress instead of waiting for heartbeat advancement"
        )
    }

    private static func testSlowHealthProbeCannotExceedTotalDeadline() async throws {
        let fixture = try ServiceFixture(printPIDs: [42])
        let clock = ManualServiceClock()
        try fixture.seedHealthyStateSequence(sequences: [1])
        fixture.runner.onLoadedPrint = { timeout in
            clock.advance(by: min(timeout, 1.25))
        }

        do {
            try await fixture.manager(
                pollAttempts: 10,
                pollIntervalNanoseconds: 1_000_000_000,
                stableHealthTimeout: 1.5,
                monotonicNow: { clock.now },
                sleep: clock.sleep
            ).install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion("slow health probe unexpectedly stabilized")
        } catch ServiceManagerError.unstableService {
            // Expected.
        }

        let healthPrintCalls = fixture.runner.calls.filter {
            $0.arguments.first == "print" && $0.timeout != 2
        }
        try require(
            healthPrintCalls.map(\.timeout) == [1.5],
            "health probe timeout was not clipped to the total remaining deadline"
        )
        try require(
            clock.now == 1.5,
            "slow health probe advanced beyond the total monotonic deadline"
        )
        try require(
            clock.sleeps == [250_000_000],
            "poll sleep was not clipped to the remaining total deadline"
        )
    }

    private static func testPriorJobPrintTimeoutAbortsBeforeAnyMutation() async throws {
        let fixture = try ServiceFixture(loaded: true)
        let previousData = Data("previous plist".utf8)
        fixture.fileSystem.seed(previousData, at: fixture.plistURL)
        fixture.runner.printError = ServiceManagerError.commandTimedOut(
            command: "launchctl print"
        )

        do {
            try await fixture.manager().install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion("install continued after prior-job print timeout")
        } catch ServiceManagerError.commandTimedOut {
            // Expected.
        }

        let serviceFileMutations = fixture.fileSystem.operations.filter {
            $0.hasPrefix("replace:")
                || $0.hasPrefix("remove:")
                || ($0.hasPrefix("write:")
                    && !$0.hasSuffix("/data/control.json"))
        }
        try require(
            serviceFileMutations.isEmpty,
            "prior-job print timeout mutated a managed service file"
        )
        let retainedData = try fixture.fileSystem.readData(at: fixture.plistURL)
        try require(
            retainedData == previousData,
            "prior-job print timeout changed the existing plist"
        )
        let controlURL = fixture.supportURL.appendingPathComponent("data/control.json")
        let control = try JSONSerialization.jsonObject(
            with: fixture.fileSystem.readData(at: controlURL)
        ) as? [String: Any]
        try require(
            control?["protection_enabled"] as? Bool == false,
            "prior-job print timeout did not leave protection disabled"
        )
        try require(
            fixture.runner.calls.map(\.arguments) == [
                ["print", "gui/501/com.wuyi.mac-face-lock-agent"],
            ],
            "prior-job print timeout continued into launchctl mutation"
        )
    }

    private static func testPriorJobUnexpectedPrintFailureAbortsBeforeAnyMutation() async throws {
        let fixture = try ServiceFixture()
        let previousData = Data("previous plist".utf8)
        fixture.fileSystem.seed(previousData, at: fixture.plistURL)
        fixture.runner.unloadedPrintExitCode = 5

        do {
            try await fixture.manager().install(
                appURL: fixture.appURL,
                supportURL: fixture.supportURL
            )
            throw TestFailure.assertion(
                "install treated unexpected launchctl print failure as absence"
            )
        } catch ServiceManagerError.commandFailed(
            let command,
            let exitCode,
            _
        ) {
            try require(command.contains("launchctl print"), "wrong command failure surfaced")
            try require(exitCode == 5, "unexpected print exit code was not preserved")
        }

        let serviceFileMutations = fixture.fileSystem.operations.filter {
            $0.hasPrefix("replace:")
                || $0.hasPrefix("remove:")
                || ($0.hasPrefix("write:")
                    && !$0.hasSuffix("/data/control.json"))
        }
        try require(
            serviceFileMutations.isEmpty,
            "unexpected print failure mutated a managed service file"
        )
        let retainedData = try fixture.fileSystem.readData(at: fixture.plistURL)
        try require(
            retainedData == previousData,
            "unexpected print failure changed the existing plist"
        )
        let controlURL = fixture.supportURL.appendingPathComponent("data/control.json")
        let control = try JSONSerialization.jsonObject(
            with: fixture.fileSystem.readData(at: controlURL)
        ) as? [String: Any]
        try require(
            control?["protection_enabled"] as? Bool == false,
            "unexpected print failure did not leave protection disabled"
        )
        try require(
            fixture.runner.calls.map(\.arguments) == [
                ["print", "gui/501/com.wuyi.mac-face-lock-agent"],
            ],
            "unexpected print failure continued into launchctl mutation"
        )
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

    private static func plistDataWithDuplicateEntry(
        _ data: Data,
        key: String,
        valueXML: String
    ) throws -> Data {
        guard var xml = String(data: data, encoding: .utf8),
              let closingDictionary = xml.range(of: "</dict>") else {
            throw TestFailure.assertion("plist was not XML for duplicate-key fixture")
        }
        xml.insert(
            contentsOf: "<key>\(key)</key>\(valueXML)",
            at: closingDictionary.lowerBound
        )
        guard let duplicateData = xml.data(using: .utf8) else {
            throw TestFailure.assertion("duplicate-key fixture was not UTF-8")
        }
        return duplicateData
    }

    private static func plistDataWithCDATAKeyBeforeExistingEntry(
        _ data: Data,
        key: String,
        valueXML: String
    ) throws -> Data {
        guard var xml = String(data: data, encoding: .utf8),
              let openingDictionary = xml.range(of: "<dict>") else {
            throw TestFailure.assertion("plist was not XML for CDATA-key fixture")
        }
        xml.insert(
            contentsOf: "<key><![CDATA[\(key)]]></key>\(valueXML)",
            at: openingDictionary.upperBound
        )
        guard let duplicateData = xml.data(using: .utf8) else {
            throw TestFailure.assertion("CDATA-key fixture was not UTF-8")
        }
        return duplicateData
    }
}
