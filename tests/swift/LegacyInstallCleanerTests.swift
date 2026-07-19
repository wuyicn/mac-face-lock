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

private enum TestCommandError: Error {
    case injected
}

private struct RecordedServiceCommand {
    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval
}

private func absentServiceResult(
    arguments: [String],
    bootoutExitCode: Int32 = 0
) -> ServiceCommandResult {
    let service = arguments.last ?? ""
    if arguments.first == "print" {
        return ServiceCommandResult(
            exitCode: 113,
            stdout: "",
            stderr: "Bad request.\nCould not find service \"\(service)\""
        )
    }
    return ServiceCommandResult(
        exitCode: bootoutExitCode,
        stdout: "",
        stderr: bootoutExitCode == 0 ? "" : "No such process"
    )
}

private func plistData(_ dictionary: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(
        fromPropertyList: dictionary,
        format: .xml,
        options: 0
    )
}

private func replaceFileAtomically(at url: URL, with data: Data) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
        ".replacement-\(UUID().uuidString)"
    )
    try data.write(to: temporary)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: temporary, to: url)
}

private final class RecordingServiceCommandRunner: ServiceCommandRunning {
    private(set) var calls: [RecordedServiceCommand] = []
    var resultProvider: ((Int, [String]) throws -> ServiceCommandResult)?

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ServiceCommandResult {
        calls.append(
            RecordedServiceCommand(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout
            )
        )
        if let resultProvider {
            return try resultProvider(calls.count, arguments)
        }
        return absentServiceResult(arguments: arguments)
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

    init(
        appURLInsideLegacyRoot: Bool = false,
        supportRelativeToLegacyRoot: String? = nil,
        testEventHandler: ((String) throws -> Void)? = nil
    ) throws {
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
        if let supportRelativeToLegacyRoot {
            supportURL = supportRelativeToLegacyRoot.isEmpty
                ? legacyRoot
                : legacyRoot.appendingPathComponent(
                    supportRelativeToLegacyRoot,
                    isDirectory: true
                )
        } else {
            supportURL = home.appendingPathComponent(
                "Library/Application Support/Mac Face Lock",
                isDirectory: true
            )
        }
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
            userID: getuid(),
            testEventHandler: testEventHandler
        )
    }

    var agentURL: URL {
        launchAgentsURL.appendingPathComponent(Self.agentName)
    }

    var statusURL: URL {
        launchAgentsURL.appendingPathComponent(Self.statusName)
    }

    var journalURL: URL {
        supportURL.appendingPathComponent("legacy-cleanup-v1.json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }

    func installKnownLegacyPairAndData() throws {
        try writeCurrentAgentPlist()
        try writeUnifiedStatusPlist()
        try write("config/config.json", #"{"enabled":true}"#)
        try write("data/face-template.bin", "legacy-face-data")
        try write("logs/agent.out.log", "legacy-log")
        try write(
            "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent",
            "legacy-agent"
        )
        try write(
            "dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock",
            "legacy-app"
        )
        try write(
            "dist/Mac Face Lock Status.app/Contents/MacOS/MacFaceLockStatus",
            "legacy-status"
        )
    }

    func confirmedCandidate() throws -> LegacyCleanupCandidate {
        guard case .confirmed(let candidate) = cleaner.inspect() else {
            throw TestFailure.assertion("fixture did not produce a confirmed candidate")
        }
        return candidate
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = legacyRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func writeSupport(_ relativePath: String, _ contents: String) throws {
        let url = supportURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func requireAllowlistedTargetsAbsent() throws {
        for target in [
            "config/config.json",
            "data",
            "logs",
            "dist/Mac Face Lock Agent.app",
            "dist/Mac Face Lock.app",
            "dist/Mac Face Lock Status.app",
        ] {
            try require(
                !FileManager.default.fileExists(
                    atPath: legacyRoot.appendingPathComponent(target).path
                ),
                "allowlisted target remains: \(target)"
            )
        }
        try require(
            !FileManager.default.fileExists(atPath: agentURL.path),
            "legacy Agent plist remains"
        )
        try require(
            !FileManager.default.fileExists(atPath: statusURL.path),
            "legacy Status plist remains"
        )
    }

    func requirePreserved(_ relativePath: String) throws {
        try require(
            FileManager.default.fileExists(
                atPath: legacyRoot.appendingPathComponent(relativePath).path
            ),
            "sentinel was removed: \(relativePath)"
        )
    }

    func requireSupportPreserved(_ relativePath: String) throws {
        try require(
            FileManager.default.fileExists(
                atPath: supportURL.appendingPathComponent(relativePath).path
            ),
            "release Application Support data was removed: \(relativePath)"
        )
    }

    func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: legacyRoot.appendingPathComponent(relativePath).path
        )
    }

    func journalObject() throws -> [String: Any] {
        guard
            let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: journalURL)
            ) as? [String: Any]
        else {
            throw TestFailure.assertion("journal is not a JSON object")
        }
        return object
    }

    func writeJournalObject(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: journalURL)
    }

    func writeValidJournal(rootURL: URL) throws {
        var rootStat = stat()
        guard lstat(rootURL.path, &rootStat) == 0 else {
            throw TestFailure.assertion("could not stat journal root")
        }
        try writeJournalObject([
            "schema_version": 1,
            "root_path": rootURL.path,
            "root_identity": [
                "device": NSNumber(value: UInt64(rootStat.st_dev)),
                "inode": NSNumber(value: UInt64(rootStat.st_ino)),
            ],
            "relative_targets": [
                "config/config.json",
                "data",
                "logs",
                "dist/Mac Face Lock Agent.app",
                "dist/Mac Face Lock.app",
                "dist/Mac Face Lock Status.app",
            ],
            "phase": "confirmed",
        ])
        guard chmod(journalURL.path, 0o600) == 0 else {
            throw TestFailure.assertion("could not set journal mode")
        }
    }

    func writeCompletionMarker() throws {
        try Data(
            #"{"schema_version":1,"completed":true}"#.utf8
        ).write(to: journalURL)
        guard chmod(journalURL.path, 0o600) == 0 else {
            throw TestFailure.assertion("could not set completion marker mode")
        }
    }

    func makeCleaner(userID: uid_t) -> LegacyInstallCleaner {
        LegacyInstallCleaner(
            homeURL: home,
            appURL: appURL,
            supportURL: supportURL,
            commandRunner: commandRunner,
            userID: userID
        )
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
    static func main() async throws {
        try testInspectSurfacesIncompleteJournalBeforePlists()
        try testInspectSurfacesCompletionMarker()
        try testInspectRejectsInvalidJournalBeforePlists()
        try testAcknowledgesOnlyExactCompletionMarker()
        try testAcknowledgementRejectsIncompleteAndInvalidJournals()
        try testAcknowledgementTreatsMissingMarkerAsConsumed()
        try testInspectHasNoExecutionSideEffects()
        try await testSupportOverlapBlocksBeforeMutation()
        try await testSupportRootABABlocksBeforeMutation()
        try await testFullPreflightFailureHasNoMutation()
        try await testUnconfirmedCandidateCannotCreateJournal()
        try await testNonLoadedServicesAreAccepted()
        try await testRejectsNonAbsentPrintFailures()
        try await testRejectsAbsentStderrWithNonemptyStdout()
        try await testFinalVerificationRejectsNonAbsentPrintFailure()
        try await testCommandFailureBlocksDeletion()
        try await testLoadedServiceBlocksDeletion()
        try await testSourceDeletionFailurePreservesPlists()
        try await testFailureAfterSourceDeletionIsIncomplete()
        try await testRetryRecoversInterruptedSourceTombstone()
        try await testRetryRecoversInterruptedFileAndDirectoryPurges()
        try await testChangedPurgeReplacementSurvivesCleanerRetry()
        try await testInvalidAndUnknownPurgeJournalSchemaIsBlocked()
        try await testInitialPlistReplacementBlocksDeletion()
        try await testInitialInPlacePlistMutationBlocksDeletion()
        try await testRetryPlistReplacementBlocksDeletion()
        try await testRetryIsIdempotentWithAbsentTargets()
        try await testRetryCompletesWithoutLaunchAgentsDirectory()
        try await testRetryRejectsReleaseSupportOverlap()
        try await testRetryRejectsInvalidJournalMetadata()
        try await testRetryRejectsTamperedJournalFields()
        try await testRetryRejectsChangedRootIdentity()
        try await testCompletedRetryIsANoOp()
        try await testSuccessfulCleanupDeletesOnlyAllowlist()
        try testRejectsCurrentAppInsideCandidateRoot()
        try testRecognizesInstalledCurrentPair()
        try testRecognizesInstalledHistoricalPair()
        try testRecognizesHistoricalStatusSchema()
        try testRecognizesUnifiedStatusWithHistoricalKeepAlive()
        try testNoPlistsIsNotFound()
        try testCurrentReleaseAgentWithoutStatusIsNotFound()
        try testOnlyOneSourcePlistIsAmbiguous()
        try await testRemovesOnlyExactKnownOrphanRegistrationAndPreservesSourceData()
        try await testOrphanRecoveryRejectsUnknownMixedAndChangedRegistrations()
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

    private static func testInspectSurfacesIncompleteJournalBeforePlists() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeValidJournal(rootURL: fixture.legacyRoot)

        guard case .cleanupIncomplete = fixture.cleaner.inspect() else {
            throw TestFailure.assertion(
                "valid incomplete journal did not override absent legacy plists"
            )
        }
        try require(
            fixture.commandRunner.calls.isEmpty,
            "journal inspection unexpectedly ran launchctl"
        )
    }

    private static func testInspectSurfacesCompletionMarker() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeCompletionMarker()

        guard case .completed = fixture.cleaner.inspect() else {
            throw TestFailure.assertion(
                "completion marker was not surfaced explicitly"
            )
        }
        try require(
            fixture.commandRunner.calls.isEmpty,
            "completion inspection unexpectedly ran launchctl"
        )
    }

    private static func testInspectRejectsInvalidJournalBeforePlists() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeJournalObject([
            "schema_version": 1,
            "completed": false,
            "unexpected": true,
        ])
        guard chmod(fixture.journalURL.path, 0o600) == 0 else {
            throw TestFailure.assertion("could not set invalid journal mode")
        }

        guard case .ambiguous = fixture.cleaner.inspect() else {
            throw TestFailure.assertion(
                "invalid journal was ignored when legacy plists were absent"
            )
        }
        try require(
            fixture.commandRunner.calls.isEmpty,
            "invalid journal inspection unexpectedly ran launchctl"
        )
    }

    private static func testAcknowledgesOnlyExactCompletionMarker() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeCompletionMarker()
        try fixture.writeSupport("keep.txt", "preserve")

        try fixture.cleaner.acknowledgeCompletion()

        try require(
            !FileManager.default.fileExists(atPath: fixture.journalURL.path),
            "completion acknowledgement did not remove the exact marker"
        )
        try require(
            FileManager.default.fileExists(
                atPath: fixture.supportURL.appendingPathComponent("keep.txt").path
            ),
            "completion acknowledgement removed unrelated support data"
        )
    }

    private static func testAcknowledgementRejectsIncompleteAndInvalidJournals()
        throws {
        do {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.writeValidJournal(rootURL: fixture.legacyRoot)

            var rejected = false
            do {
                try fixture.cleaner.acknowledgeCompletion()
            } catch {
                rejected = true
            }
            try require(rejected, "incomplete journal was acknowledged")
            try require(
                FileManager.default.fileExists(atPath: fixture.journalURL.path),
                "incomplete journal was removed during acknowledgement"
            )
        }

        do {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try Data(
                #"{"completed":true,"schema_version":1}"#.utf8
            ).write(to: fixture.journalURL)
            guard chmod(fixture.journalURL.path, 0o600) == 0 else {
                throw TestFailure.assertion("could not set invalid marker mode")
            }
            guard case .ambiguous = fixture.cleaner.inspect() else {
                throw TestFailure.assertion(
                    "noncanonical completion bytes were accepted during inspection"
                )
            }

            var rejected = false
            do {
                try fixture.cleaner.acknowledgeCompletion()
            } catch {
                rejected = true
            }
            try require(rejected, "noncanonical completion bytes were acknowledged")
            try require(
                FileManager.default.fileExists(atPath: fixture.journalURL.path),
                "invalid journal was removed during acknowledgement"
            )
        }
    }

    private static func testAcknowledgementTreatsMissingMarkerAsConsumed() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }

        try fixture.cleaner.acknowledgeCompletion()

        try require(
            !FileManager.default.fileExists(atPath: fixture.journalURL.path),
            "missing marker acknowledgement created a journal"
        )
    }

    private static func testInspectHasNoExecutionSideEffects() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()

        guard case .confirmed = fixture.cleaner.inspect() else {
            throw TestFailure.assertion("known legacy pair was not confirmed")
        }
        try require(
            fixture.commandRunner.calls.isEmpty,
            "inspect unexpectedly ran launchctl"
        )
        try require(
            !FileManager.default.fileExists(atPath: fixture.journalURL.path),
            "inspect unexpectedly wrote a journal"
        )
        try fixture.requirePreserved("data/face-template.bin")
        try fixture.requirePreserved("logs/agent.out.log")
    }

    private static func testSupportOverlapBlocksBeforeMutation() async throws {
        for relativeSupport in ["", "data", "data/release-support", "dist"] {
            let fixture = try LegacyCleanerFixture(
                supportRelativeToLegacyRoot: relativeSupport
            )
            defer { fixture.remove() }
            try fixture.writeCurrentAgentPlist()
            try fixture.writeUnifiedStatusPlist()
            try fixture.write("README.md", "preserve")
            let candidate = try fixture.confirmedCandidate()

            guard case .ambiguous = await fixture.cleaner.clean(candidate) else {
                throw TestFailure.assertion(
                    "overlapping support path was accepted: \(relativeSupport)"
                )
            }
            try require(
                fixture.commandRunner.calls.isEmpty,
                "support overlap ran launchctl: \(relativeSupport)"
            )
            try require(
                !FileManager.default.fileExists(atPath: fixture.journalURL.path),
                "support overlap created a journal: \(relativeSupport)"
            )
            try fixture.requirePreserved("README.md")
            try require(
                FileManager.default.fileExists(atPath: fixture.agentURL.path)
                    && FileManager.default.fileExists(atPath: fixture.statusURL.path),
                "support overlap deleted a plist: \(relativeSupport)"
            )
        }
    }

    private static func testFullPreflightFailureHasNoMutation() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        let external = fixture.container.appendingPathComponent("external-data")
        try Data("preserve".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: fixture.legacyRoot.appendingPathComponent("data/unsafe-link"),
            withDestinationURL: external
        )
        let candidate = try fixture.confirmedCandidate()

        guard case .ambiguous = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion("unsafe preflight did not block cleanup")
        }
        try require(
            fixture.commandRunner.calls.isEmpty,
            "preflight failure unexpectedly ran launchctl"
        )
        try require(
            !FileManager.default.fileExists(atPath: fixture.journalURL.path),
            "preflight failure unexpectedly created a journal"
        )
        try require(
            fixture.fileExists("data/face-template.bin"),
            "preflight failure deleted legacy data"
        )
        try require(
            FileManager.default.fileExists(atPath: fixture.agentURL.path)
                && FileManager.default.fileExists(atPath: fixture.statusURL.path),
            "preflight failure deleted a plist"
        )
    }

    private static func testSupportRootABABlocksBeforeMutation() async throws {
        var replacement: (() throws -> Void)?
        let fixture = try LegacyCleanerFixture(testEventHandler: { event in
            if event == "beforeJournalRename" {
                try replacement?()
            }
        })
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        try fixture.writeSupport("release.json", #"{"release":true}"#)
        let candidate = try fixture.confirmedCandidate()
        let displaced = fixture.supportURL.deletingLastPathComponent()
            .appendingPathComponent(
                "Mac Face Lock.displaced-\(UUID().uuidString)",
                isDirectory: true
            )

        replacement = {
            try FileManager.default.moveItem(
                at: fixture.supportURL,
                to: displaced
            )
            try FileManager.default.createDirectory(
                at: fixture.supportURL,
                withIntermediateDirectories: false
            )
            try FileManager.default.removeItem(at: fixture.supportURL)
            try FileManager.default.moveItem(
                at: displaced,
                to: fixture.supportURL
            )
        }

        guard case .ambiguous = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion(
                "support root A-B-A replacement was accepted"
            )
        }
        try require(
            fixture.commandRunner.calls.isEmpty,
            "support root replacement ran launchctl"
        )
        try require(
            !FileManager.default.fileExists(atPath: fixture.journalURL.path),
            "support root replacement created a journal"
        )
        try fixture.requireSupportPreserved("release.json")
        try fixture.requirePreserved("data/face-template.bin")
        try require(
            FileManager.default.fileExists(atPath: fixture.agentURL.path)
                && FileManager.default.fileExists(atPath: fixture.statusURL.path),
            "support root replacement deleted a plist"
        )
    }

    private static func testUnconfirmedCandidateCannotCreateJournal() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        let candidate = try fixture.confirmedCandidate()
        let forged = LegacyCleanupCandidate(
            rootURL: candidate.rootURL,
            rootIdentity: SecureFileIdentity(
                device: candidate.rootIdentity.device,
                inode: candidate.rootIdentity.inode &+ 1
            ),
            agentPlistIdentity: candidate.agentPlistIdentity,
            statusPlistIdentity: candidate.statusPlistIdentity
        )

        guard case .ambiguous = await fixture.cleaner.clean(forged) else {
            throw TestFailure.assertion("unconfirmed candidate was accepted")
        }
        try require(
            !FileManager.default.fileExists(atPath: fixture.journalURL.path),
            "unconfirmed candidate created a journal"
        )
        try require(
            fixture.commandRunner.calls.isEmpty,
            "unconfirmed candidate ran launchctl"
        )
        try require(
            fixture.fileExists("data/face-template.bin"),
            "unconfirmed candidate deleted data"
        )
    }

    private static func testNonLoadedServicesAreAccepted() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        fixture.commandRunner.resultProvider = { _, arguments in
            absentServiceResult(
                arguments: arguments,
                bootoutExitCode: 3
            )
        }
        let candidate = try fixture.confirmedCandidate()

        let result = await fixture.cleaner.clean(candidate)
        try require(
            result == .notFound,
            "already-unloaded jobs blocked cleanup"
        )
        try fixture.requireAllowlistedTargetsAbsent()
    }

    private static func testRejectsNonAbsentPrintFailures() async throws {
        let failures: [(Int32, String)] = [
            (1, ""),
            (77, "Permission denied"),
            (113, "Bad request.\nCould not find service in another domain"),
            (5, "Internal launchctl error"),
        ]
        for (exitCode, stderr) in failures {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.installKnownLegacyPairAndData()
            fixture.commandRunner.resultProvider = { _, arguments in
                if arguments.first == "print" {
                    return ServiceCommandResult(
                        exitCode: exitCode,
                        stdout: "",
                        stderr: stderr
                    )
                }
                return absentServiceResult(arguments: arguments)
            }
            let candidate = try fixture.confirmedCandidate()

            guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
                throw TestFailure.assertion(
                    "non-absent print failure was accepted: \(exitCode), \(stderr)"
                )
            }
            try require(
                fixture.fileExists("data/face-template.bin"),
                "non-absent print failure deleted source data"
            )
            try require(
                FileManager.default.fileExists(atPath: fixture.agentURL.path)
                    && FileManager.default.fileExists(atPath: fixture.statusURL.path),
                "non-absent print failure deleted a plist"
            )
        }
    }

    private static func testFinalVerificationRejectsNonAbsentPrintFailure()
        async throws
    {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        fixture.commandRunner.resultProvider = { callIndex, arguments in
            if callIndex == 5 {
                return ServiceCommandResult(
                    exitCode: 77,
                    stdout: "",
                    stderr: "Permission denied"
                )
            }
            return absentServiceResult(arguments: arguments)
        }
        let candidate = try fixture.confirmedCandidate()

        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion(
                "final non-absent print failure was accepted"
            )
        }
        try fixture.requireAllowlistedTargetsAbsent()
        let journal = try fixture.journalObject()
        try require(
            journal["phase"] as? String == "plistsRemoved",
            "final print failure did not retain retry phase"
        )
    }

    private static func testRejectsAbsentStderrWithNonemptyStdout() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        fixture.commandRunner.resultProvider = { _, arguments in
            let absent = absentServiceResult(arguments: arguments)
            guard arguments.first == "print" else {
                return absent
            }
            return ServiceCommandResult(
                exitCode: absent.exitCode,
                stdout: "unexpected output",
                stderr: absent.stderr
            )
        }
        let candidate = try fixture.confirmedCandidate()

        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion(
                "missing-service stderr with nonempty stdout was accepted"
            )
        }
        try require(
            fixture.fileExists("data/face-template.bin"),
            "nonempty print stdout deleted source data"
        )
        try require(
            FileManager.default.fileExists(atPath: fixture.agentURL.path)
                && FileManager.default.fileExists(atPath: fixture.statusURL.path),
            "nonempty print stdout deleted a plist"
        )
    }

    private static func testCommandFailureBlocksDeletion() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        fixture.commandRunner.resultProvider = { callIndex, arguments in
            if callIndex == 1 {
                throw TestCommandError.injected
            }
            return absentServiceResult(arguments: arguments)
        }
        let candidate = try fixture.confirmedCandidate()

        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion("command failure was not retryable")
        }
        try require(
            FileManager.default.fileExists(atPath: fixture.journalURL.path),
            "command failure did not preserve the journal"
        )
        var journalStat = stat()
        try require(
            lstat(fixture.journalURL.path, &journalStat) == 0
                && journalStat.st_uid == getuid()
                && journalStat.st_mode & 0o777 == 0o600,
            "incomplete journal was not current-user-owned mode 0600"
        )
        let journal = try fixture.journalObject()
        try require(
            journal["schema_version"] as? Int == 1
                && journal["root_path"] as? String == fixture.legacyRoot.path
                && journal["phase"] as? String == "confirmed",
            "incomplete journal did not record the confirmed phase"
        )
        try require(
            fixture.fileExists("data/face-template.bin"),
            "command failure deleted source data"
        )
        try require(
            FileManager.default.fileExists(atPath: fixture.agentURL.path)
                && FileManager.default.fileExists(atPath: fixture.statusURL.path),
            "command failure deleted legacy plists"
        )
    }

    private static func testLoadedServiceBlocksDeletion() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        fixture.commandRunner.resultProvider = { callIndex, arguments in
            if callIndex == 2 {
                return ServiceCommandResult(
                    exitCode: 0,
                    stdout: "",
                    stderr: ""
                )
            }
            return absentServiceResult(
                arguments: arguments,
                bootoutExitCode: 5
            )
        }
        let candidate = try fixture.confirmedCandidate()

        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion("loaded service did not block cleanup")
        }
        try require(
            fixture.fileExists("data/face-template.bin"),
            "loaded service allowed source deletion"
        )
        try require(
            FileManager.default.fileExists(atPath: fixture.agentURL.path)
                && FileManager.default.fileExists(atPath: fixture.statusURL.path),
            "loaded service allowed plist deletion"
        )
    }

    private static func testSourceDeletionFailurePreservesPlists() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        let configDirectory = fixture.legacyRoot.appendingPathComponent("config")
        guard chmod(configDirectory.path, 0o500) == 0 else {
            throw TestFailure.assertion("could not protect config fixture")
        }
        defer { _ = chmod(configDirectory.path, 0o700) }
        let candidate = try fixture.confirmedCandidate()

        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion("source deletion failure was not retryable")
        }
        try require(
            fixture.fileExists("config/config.json"),
            "protected source target was unexpectedly removed"
        )
        try require(
            FileManager.default.fileExists(atPath: fixture.statusURL.path)
                && FileManager.default.fileExists(atPath: fixture.agentURL.path),
            "plists were removed before source-target removal completed"
        )
        let journal = try fixture.journalObject()
        try require(
            journal["phase"] as? String == "servicesStopped",
            "source deletion failure recorded the wrong phase"
        )
    }

    private static func testFailureAfterSourceDeletionIsIncomplete() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        fixture.commandRunner.resultProvider = { callIndex, arguments in
            if callIndex == 5 {
                return ServiceCommandResult(
                    exitCode: 0,
                    stdout: "",
                    stderr: ""
                )
            }
            return absentServiceResult(arguments: arguments)
        }
        let candidate = try fixture.confirmedCandidate()

        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion(
                "post-deletion verification failure was not retryable"
            )
        }
        try fixture.requireAllowlistedTargetsAbsent()
        let journal = try fixture.journalObject()
        try require(
            journal["phase"] as? String == "plistsRemoved",
            "post-deletion failure did not preserve the last durable phase"
        )
        try require(
            journal["root_path"] as? String == fixture.legacyRoot.path,
            "incomplete journal lost the root needed for retry"
        )
    }

    private static func testInitialPlistReplacementBlocksDeletion() async throws {
        var replacement: (() throws -> Void)?
        let fixture = try LegacyCleanerFixture(testEventHandler: { event in
            if event == "beforeInitialPlistRemoval" {
                try replacement?()
            }
        })
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        let replacementData = try plistData(fixture.releaseAgentDictionary())
        let agentURL = fixture.agentURL
        replacement = {
            try replaceFileAtomically(at: agentURL, with: replacementData)
        }
        let candidate = try fixture.confirmedCandidate()

        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion("initial Agent replacement was deleted")
        }
        try require(
            FileManager.default.fileExists(atPath: agentURL.path),
            "replacement release Agent plist was removed"
        )
        let persistedAgent = try Data(contentsOf: agentURL)
        try require(
            persistedAgent == replacementData,
            "replacement release Agent plist was changed"
        )
    }

    private static func testRetryRecoversInterruptedSourceTombstone() async throws {
        let fixture = try LegacyCleanerFixture(testEventHandler: { event in
            if event == "afterSourceTombstoneRename" {
                throw TestFailure.assertion("simulated source interruption")
            }
        })
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        let candidate = try fixture.confirmedCandidate()

        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion(
                "interruption after source rename was not retryable"
            )
        }
        let journal = try fixture.journalObject()
        guard let tombstones = journal["tombstones"] as? [[String: Any]],
              !tombstones.isEmpty else {
            throw TestFailure.assertion(
                "interrupted cleanup did not journal tombstone identities"
            )
        }

        let retryCleaner = fixture.makeCleaner(userID: getuid())
        let result = await retryCleaner.retry()
        try require(result == .notFound, "tombstone recovery did not complete")
        try fixture.requireAllowlistedTargetsAbsent()
    }

    private static func testRetryRecoversInterruptedFileAndDirectoryPurges()
        async throws
    {
        for (target, expectedKind) in [
            ("config/config.json", "file"),
            ("data", "directory"),
        ] {
            let fixture = try LegacyCleanerFixture(testEventHandler: { event in
                if event == "afterSourcePurgeRename:\(target)" {
                    throw TestFailure.assertion("simulated purge interruption")
                }
            })
            defer { fixture.remove() }
            try fixture.installKnownLegacyPairAndData()
            let candidate = try fixture.confirmedCandidate()

            guard case .cleanupIncomplete =
                await fixture.cleaner.clean(candidate) else {
                throw TestFailure.assertion(
                    "\(target) purge interruption was not retryable"
                )
            }
            let purge = try journalPurge(
                fixture,
                originalRelativePath: target
            )
            try require(
                purge["kind"] as? String == expectedKind,
                "\(target) purge recorded the wrong kind"
            )
            try require(
                (purge["identity"] as? [String: Any])?.count == 2,
                "\(target) purge did not record its exact identity"
            )
            guard let purgePath = purge["purge_relative_path"] as? String else {
                throw TestFailure.assertion("\(target) purge path is missing")
            }
            try require(
                FileManager.default.fileExists(
                    atPath: fixture.legacyRoot.appendingPathComponent(
                        purgePath
                    ).path
                ),
                "\(target) durable purge was not present after interruption"
            )

            let retryCleaner = fixture.makeCleaner(userID: getuid())
            let result = await retryCleaner.retry()
            try require(
                result == .notFound,
                "fresh cleaner did not recover \(target) purge: \(result)"
            )
            try fixture.requireAllowlistedTargetsAbsent()
        }
    }

    private static func testChangedPurgeReplacementSurvivesCleanerRetry()
        async throws
    {
        let target = "config/config.json"
        let fixture = try LegacyCleanerFixture(testEventHandler: { event in
            if event == "afterSourcePurgeRename:\(target)" {
                throw TestFailure.assertion("simulated purge interruption")
            }
        })
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        let candidate = try fixture.confirmedCandidate()
        guard case .cleanupIncomplete =
            await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion("purge replacement fixture did not stop")
        }
        let purge = try journalPurge(
            fixture,
            originalRelativePath: target
        )
        guard let purgePath = purge["purge_relative_path"] as? String else {
            throw TestFailure.assertion("purge replacement path is missing")
        }
        let purgeURL = fixture.legacyRoot.appendingPathComponent(purgePath)
        try FileManager.default.removeItem(at: purgeURL)
        try Data("replacement-must-survive".utf8).write(to: purgeURL)

        guard case .ambiguous =
            await fixture.makeCleaner(userID: getuid()).retry() else {
            throw TestFailure.assertion("changed purge replacement was accepted")
        }
        let replacement = try Data(contentsOf: purgeURL)
        try require(
            replacement == Data("replacement-must-survive".utf8),
            "changed purge replacement was deleted or modified"
        )
    }

    private static func testInvalidAndUnknownPurgeJournalSchemaIsBlocked()
        async throws
    {
        for mutation in ["unknown_key", "invalid_path"] {
            let target = "config/config.json"
            let fixture = try LegacyCleanerFixture(testEventHandler: { event in
                if event == "afterSourcePurgeRename:\(target)" {
                    throw TestFailure.assertion("simulated purge interruption")
                }
            })
            defer { fixture.remove() }
            try fixture.installKnownLegacyPairAndData()
            let candidate = try fixture.confirmedCandidate()
            guard case .cleanupIncomplete =
                await fixture.cleaner.clean(candidate) else {
                throw TestFailure.assertion(
                    "\(mutation) purge schema fixture did not stop"
                )
            }
            var journal = try fixture.journalObject()
            guard var tombstones = journal["tombstones"] as? [[String: Any]],
                  var purges = tombstones[0]["purges"] as? [[String: Any]],
                  !purges.isEmpty else {
                throw TestFailure.assertion(
                    "\(mutation) purge schema fixture is missing"
                )
            }
            if mutation == "unknown_key" {
                purges[0]["unknown"] = true
            } else {
                purges[0]["purge_relative_path"] =
                    "unrelated/.mac-face-lock-purge-outside"
            }
            tombstones[0]["purges"] = purges
            journal["tombstones"] = tombstones
            try fixture.writeJournalObject(journal)
            let callsBefore = fixture.commandRunner.calls.count

            let retryCleaner = fixture.makeCleaner(userID: getuid())
            guard case .ambiguous = await retryCleaner.retry() else {
                throw TestFailure.assertion(
                    "\(mutation) purge schema was accepted"
                )
            }
            try require(
                fixture.commandRunner.calls.count == callsBefore,
                "\(mutation) purge schema ran service commands"
            )
        }
    }

    private static func journalPurge(
        _ fixture: LegacyCleanerFixture,
        originalRelativePath: String
    ) throws -> [String: Any] {
        let journal = try fixture.journalObject()
        guard let tombstones = journal["tombstones"] as? [[String: Any]] else {
            throw TestFailure.assertion("journal tombstones are missing")
        }
        for tombstone in tombstones {
            guard let purges = tombstone["purges"] as? [[String: Any]] else {
                continue
            }
            if let purge = purges.first(where: {
                $0["original_relative_path"] as? String
                    == originalRelativePath
            }) {
                return purge
            }
        }
        throw TestFailure.assertion(
            "journal purge is missing: \(originalRelativePath)"
        )
    }

    private static func testInitialInPlacePlistMutationBlocksDeletion() async throws {
        var mutation: (() throws -> Void)?
        let fixture = try LegacyCleanerFixture(testEventHandler: { event in
            if event == "beforeInitialPlistRemoval" {
                try mutation?()
            }
        })
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        let unrelatedData = try plistData([
            "Label": "com.example.unrelated-status",
        ])
        let statusURL = fixture.statusURL
        mutation = {
            try unrelatedData.write(to: statusURL)
        }
        let candidate = try fixture.confirmedCandidate()

        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion("in-place Status mutation was deleted")
        }
        try require(
            FileManager.default.fileExists(atPath: statusURL.path),
            "in-place unrelated Status plist was removed"
        )
        let persistedStatus = try Data(contentsOf: statusURL)
        try require(
            persistedStatus == unrelatedData,
            "in-place unrelated Status plist was changed"
        )
        try require(
            FileManager.default.fileExists(atPath: fixture.agentURL.path),
            "Agent plist was removed after Status mutation"
        )
    }

    private static func testRetryPlistReplacementBlocksDeletion() async throws {
        var replacement: (() throws -> Void)?
        let fixture = try LegacyCleanerFixture(testEventHandler: { event in
            if event == "beforeRetryPlistRemoval" {
                try replacement?()
            }
        })
        defer { fixture.remove() }
        try await prepareConfirmedJournal(fixture)
        let replacementData = try plistData(fixture.releaseAgentDictionary())
        let agentURL = fixture.agentURL
        replacement = {
            try replaceFileAtomically(at: agentURL, with: replacementData)
        }

        guard case .cleanupIncomplete = await fixture.cleaner.retry() else {
            throw TestFailure.assertion("retry Agent replacement was deleted")
        }
        try require(
            FileManager.default.fileExists(atPath: agentURL.path),
            "retry replacement release Agent plist was removed"
        )
        let persistedAgent = try Data(contentsOf: agentURL)
        try require(
            persistedAgent == replacementData,
            "retry replacement release Agent plist was changed"
        )
    }

    private static func testRetryIsIdempotentWithAbsentTargets() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        let configDirectory = fixture.legacyRoot.appendingPathComponent("config")
        guard chmod(configDirectory.path, 0o500) == 0 else {
            throw TestFailure.assertion("could not protect retry fixture")
        }
        let candidate = try fixture.confirmedCandidate()
        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion("retry fixture did not stop mid-cleanup")
        }
        guard chmod(configDirectory.path, 0o700) == 0 else {
            throw TestFailure.assertion("could not restore retry fixture permissions")
        }
        let alreadyAbsent = "data"
        try FileManager.default.removeItem(
            at: fixture.legacyRoot.appendingPathComponent(alreadyAbsent)
        )
        try FileManager.default.removeItem(at: fixture.statusURL)
        try require(
            !fixture.fileExists(alreadyAbsent),
            "retry fixture did not contain an already-absent target"
        )
        try require(
            !FileManager.default.fileExists(atPath: fixture.statusURL.path),
            "retry fixture did not contain an already-absent plist"
        )

        let result = await fixture.cleaner.retry()

        try require(result == .notFound, "valid retry did not finish: \(result)")
        try fixture.requireAllowlistedTargetsAbsent()
        let completion = try fixture.journalObject()
        try require(
            completion.count == 2
                && completion["schema_version"] as? Int == 1
                && completion["completed"] as? Bool == true,
            "retry did not replace the journal with a completion marker"
        )
    }

    private static func testRetryCompletesWithoutLaunchAgentsDirectory()
        async throws
    {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try await prepareConfirmedJournal(fixture)
        try FileManager.default.removeItem(at: fixture.launchAgentsURL)

        let result = await fixture.cleaner.retry()

        try require(
            result == .notFound,
            "retry did not accept an absent LaunchAgents directory: \(result)"
        )
        try require(
            !FileManager.default.fileExists(atPath: fixture.launchAgentsURL.path),
            "retry recreated the absent LaunchAgents directory"
        )
        try fixture.requireAllowlistedTargetsAbsent()
    }

    private static func testRetryRejectsInvalidJournalMetadata() async throws {
        try await assertInvalidJournalBlocked("mode") { fixture in
            guard chmod(fixture.journalURL.path, 0o644) == 0 else {
                throw TestFailure.assertion("could not alter journal mode")
            }
            return fixture.cleaner
        }
        try await assertInvalidJournalBlocked("owner") { fixture in
            fixture.makeCleaner(userID: getuid() &+ 1)
        }
        try await assertInvalidJournalBlocked("hard link") { fixture in
            let sibling = fixture.supportURL.appendingPathComponent(
                "legacy-cleanup-linked.json"
            )
            guard link(fixture.journalURL.path, sibling.path) == 0 else {
                throw TestFailure.assertion("could not hard-link journal fixture")
            }
            return fixture.cleaner
        }
        try await assertInvalidJournalBlocked("symlink") { fixture in
            let external = fixture.container.appendingPathComponent(
                "external-journal.json"
            )
            try Data("outside".utf8).write(to: external)
            try FileManager.default.removeItem(at: fixture.journalURL)
            try FileManager.default.createSymbolicLink(
                at: fixture.journalURL,
                withDestinationURL: external
            )
            return fixture.cleaner
        }
        try await assertInvalidJournalBlocked("oversized") { fixture in
            try Data(repeating: 0x20, count: 64 * 1_024 + 1).write(
                to: fixture.journalURL
            )
            guard chmod(fixture.journalURL.path, 0o600) == 0 else {
                throw TestFailure.assertion("could not reset oversized journal mode")
            }
            return fixture.cleaner
        }
    }

    private static func testRetryRejectsReleaseSupportOverlap() async throws {
        for (relativeSupport, label) in [
            ("", "equal root"),
            ("data/release-support", "target descendant"),
        ] {
            let fixture = try LegacyCleanerFixture(
                supportRelativeToLegacyRoot: relativeSupport
            )
            defer { fixture.remove() }
            try fixture.write("data/preserve.bin", "preserve")
            try FileManager.default.removeItem(at: fixture.launchAgentsURL)
            try fixture.writeValidJournal(rootURL: fixture.legacyRoot)

            let result = await fixture.cleaner.retry()

            switch result {
            case .ambiguous, .cleanupIncomplete:
                break
            case .notFound, .confirmed, .completed:
                throw TestFailure.assertion(
                    "\(label) support overlap was not safely refused: \(result)"
                )
            }
            try require(
                fixture.commandRunner.calls.isEmpty,
                "\(label) support overlap ran launchctl"
            )
            try require(
                fixture.fileExists("data/preserve.bin"),
                "\(label) support overlap deleted an allowlisted target"
            )
            try require(
                FileManager.default.fileExists(atPath: fixture.journalURL.path),
                "\(label) support overlap deleted its journal"
            )
        }
    }

    private static func testRetryRejectsTamperedJournalFields() async throws {
        try await assertInvalidJournalBlocked("schema") { fixture in
            var journal = try fixture.journalObject()
            journal["schema_version"] = 2
            try fixture.writeJournalObject(journal)
            return fixture.cleaner
        }
        try await assertInvalidJournalBlocked("root path") { fixture in
            var journal = try fixture.journalObject()
            journal["root_path"] = fixture.outsideRoot.path
            try fixture.writeJournalObject(journal)
            return fixture.cleaner
        }
        try await assertInvalidJournalBlocked("root identity") { fixture in
            var journal = try fixture.journalObject()
            guard var identity = journal["root_identity"] as? [String: Any] else {
                throw TestFailure.assertion("journal root identity is missing")
            }
            let inode = identity["inode"] as? NSNumber
            identity["inode"] = NSNumber(value: (inode?.uint64Value ?? 0) &+ 1)
            journal["root_identity"] = identity
            try fixture.writeJournalObject(journal)
            return fixture.cleaner
        }
        try await assertInvalidJournalBlocked("root identity extra key") { fixture in
            var journal = try fixture.journalObject()
            guard var identity = journal["root_identity"] as? [String: Any] else {
                throw TestFailure.assertion("journal root identity is missing")
            }
            identity["unexpected"] = 1
            journal["root_identity"] = identity
            try fixture.writeJournalObject(journal)
            return fixture.cleaner
        }
        try await assertInvalidJournalBlocked("root identity string") { fixture in
            var journal = try fixture.journalObject()
            guard var identity = journal["root_identity"] as? [String: Any] else {
                throw TestFailure.assertion("journal root identity is missing")
            }
            identity["device"] = "1"
            journal["root_identity"] = identity
            try fixture.writeJournalObject(journal)
            return fixture.cleaner
        }
        try await assertInvalidJournalBlocked("root identity boolean") { fixture in
            var journal = try fixture.journalObject()
            guard var identity = journal["root_identity"] as? [String: Any] else {
                throw TestFailure.assertion("journal root identity is missing")
            }
            identity["inode"] = true
            journal["root_identity"] = identity
            try fixture.writeJournalObject(journal)
            return fixture.cleaner
        }
        try await assertInvalidJournalBlocked("root identity fractional") { fixture in
            var journal = try fixture.journalObject()
            guard var identity = journal["root_identity"] as? [String: Any] else {
                throw TestFailure.assertion("journal root identity is missing")
            }
            identity["inode"] = 1.5
            journal["root_identity"] = identity
            try fixture.writeJournalObject(journal)
            return fixture.cleaner
        }
        try await assertInvalidJournalBlocked("target allowlist") { fixture in
            var journal = try fixture.journalObject()
            journal["relative_targets"] = [
                "config/config.json",
                "data",
                "logs",
                "dist/Mac Face Lock Agent.app",
                "dist/Mac Face Lock.app",
                "dist/Mac Face Lock Status.app",
                "README.md",
            ]
            try fixture.writeJournalObject(journal)
            return fixture.cleaner
        }
    }

    private static func testRetryRejectsChangedRootIdentity() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try await prepareConfirmedJournal(fixture)
        let originalRoot = fixture.home.appendingPathComponent(
            "legacy-source-original",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.legacyRoot,
            to: originalRoot
        )
        try FileManager.default.createDirectory(
            at: fixture.legacyRoot,
            withIntermediateDirectories: true
        )
        try fixture.write("data/replacement-sentinel", "preserve")
        let callsBeforeRetry = fixture.commandRunner.calls.count

        guard case .ambiguous = await fixture.cleaner.retry() else {
            throw TestFailure.assertion("changed root identity was accepted")
        }
        try require(
            fixture.commandRunner.calls.count == callsBeforeRetry,
            "changed root identity ran launchctl"
        )
        try require(
            fixture.fileExists("data/replacement-sentinel"),
            "changed root identity allowed deletion"
        )
        try require(
            FileManager.default.fileExists(atPath: fixture.agentURL.path)
                && FileManager.default.fileExists(atPath: fixture.statusURL.path),
            "changed root identity allowed plist deletion"
        )
    }

    private static func testCompletedRetryIsANoOp() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        let candidate = try fixture.confirmedCandidate()
        let cleanResult = await fixture.cleaner.clean(candidate)
        try require(
            cleanResult == .notFound,
            "completion retry fixture did not clean"
        )
        let callsBeforeRetry = fixture.commandRunner.calls.count

        let retryResult = await fixture.cleaner.retry()
        try require(
            retryResult == .notFound,
            "completed marker was not idempotent"
        )
        try require(
            fixture.commandRunner.calls.count == callsBeforeRetry,
            "completed retry unexpectedly ran launchctl"
        )
    }

    private static func prepareConfirmedJournal(
        _ fixture: LegacyCleanerFixture
    ) async throws {
        try fixture.installKnownLegacyPairAndData()
        fixture.commandRunner.resultProvider = { callIndex, arguments in
            if callIndex == 1 {
                throw TestCommandError.injected
            }
            return absentServiceResult(arguments: arguments)
        }
        let candidate = try fixture.confirmedCandidate()
        guard case .cleanupIncomplete = await fixture.cleaner.clean(candidate) else {
            throw TestFailure.assertion("could not create an incomplete journal")
        }
        fixture.commandRunner.resultProvider = nil
    }

    private static func assertInvalidJournalBlocked(
        _ label: String,
        mutate: (LegacyCleanerFixture) throws -> LegacyInstallCleaner
    ) async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try await prepareConfirmedJournal(fixture)
        let retryCleaner = try mutate(fixture)
        let callsBeforeRetry = fixture.commandRunner.calls.count

        guard case .ambiguous = await retryCleaner.retry() else {
            throw TestFailure.assertion("\(label) journal was accepted")
        }
        try require(
            fixture.commandRunner.calls.count == callsBeforeRetry,
            "\(label) journal ran launchctl"
        )
        try require(
            fixture.fileExists("data/face-template.bin"),
            "\(label) journal allowed source deletion"
        )
        try require(
            FileManager.default.fileExists(atPath: fixture.agentURL.path)
                && FileManager.default.fileExists(atPath: fixture.statusURL.path),
            "\(label) journal allowed plist deletion"
        )
    }

    private static func testSuccessfulCleanupDeletesOnlyAllowlist() async throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.installKnownLegacyPairAndData()
        try fixture.write("README.md", "preserve")
        try fixture.write(".git/HEAD", "ref: refs/heads/main")
        try fixture.write(".worktrees/sentinel", "preserve")
        try fixture.write(".venv/bin/python", "preserve")
        try fixture.write("scripts/install.sh", "preserve")
        try fixture.write("dist/Other Tool.app/sentinel", "preserve")
        try fixture.writeSupport("onboarding/state.json", "preserve")
        let candidate = try fixture.confirmedCandidate()

        let result = await fixture.cleaner.clean(candidate)

        try require(result == .notFound, "cleanup did not finish: \(result)")
        let bootouts = fixture.commandRunner.calls
            .filter { $0.arguments.first == "bootout" }
            .map(\.arguments)
        let domain = "gui/\(getuid())"
        try require(
            bootouts == [
                ["bootout", "\(domain)/com.wuyi.mac-face-lock-status"],
                ["bootout", "\(domain)/com.wuyi.mac-face-lock-agent"],
            ],
            "services stopped in the wrong order: \(bootouts)"
        )
        try fixture.requireAllowlistedTargetsAbsent()
        try fixture.requirePreserved("README.md")
        try fixture.requirePreserved(".git/HEAD")
        try fixture.requirePreserved(".worktrees/sentinel")
        try fixture.requirePreserved(".venv/bin/python")
        try fixture.requirePreserved("scripts/install.sh")
        try fixture.requirePreserved("dist/Other Tool.app/sentinel")
        try fixture.requireSupportPreserved("onboarding/state.json")

        var journalStat = stat()
        try require(
            lstat(fixture.journalURL.path, &journalStat) == 0,
            "completion marker is missing"
        )
        try require(
            journalStat.st_mode & 0o777 == 0o600,
            "journal mode was not exactly 0600"
        )
        try require(
            journalStat.st_uid == getuid(),
            "journal owner was not the current user"
        )
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.journalURL)
        ) as? [String: Any]
        try require(
            object?.count == 2
                && object?["schema_version"] as? Int == 1
                && object?["completed"] as? Bool == true,
            "completion marker retained legacy details: \(String(describing: object))"
        )
        let completionData = try Data(contentsOf: fixture.journalURL)
        try require(
            completionData == Data(#"{"schema_version":1,"completed":true}"#.utf8),
            "completion marker bytes did not match the fixed schema"
        )
        let completionText = try String(
            contentsOf: fixture.journalURL,
            encoding: .utf8
        )
        try require(
            !completionText.contains(fixture.legacyRoot.path)
                && !completionText.contains("relative_targets"),
            "completion marker retained the old path or target list"
        )
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

    private static func testRecognizesUnifiedStatusWithHistoricalKeepAlive() throws {
        let fixture = try LegacyCleanerFixture()
        defer { fixture.remove() }
        try fixture.writeHistoricalAgentPlist()
        var status = fixture.unifiedStatusDictionary(root: fixture.legacyRoot)
        status["KeepAlive"] = true
        try fixture.writePlist(status, to: fixture.statusURL)

        guard case .confirmed = fixture.cleaner.inspect() else {
            throw TestFailure.assertion(
                "known unified status transition schema was not confirmed"
            )
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

    private static func testRemovesOnlyExactKnownOrphanRegistrationAndPreservesSourceData()
        async throws
    {
        for service in [LegacyOrphanService.agent, .status] {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.write("data/preserve.bin", "legacy-data-must-remain")
            switch service {
            case .agent:
                try fixture.writeCurrentAgentPlist()
            case .status:
                try fixture.writeUnifiedStatusPlist()
            }
            guard case .ambiguous = fixture.cleaner.inspect(),
                  let candidate = fixture.cleaner.inspectRecoverableOrphan() else {
                throw TestFailure.assertion(
                    "exact lone \(service) registration was not offered as recoverable"
                )
            }
            try require(candidate.service == service, "wrong orphan service classified")

            let result = await fixture.cleaner.removeRecoverableOrphan(candidate)

            try require(result == .notFound, "known orphan recovery remained blocked")
            try fixture.requirePreserved("data/preserve.bin")
            try require(
                !FileManager.default.fileExists(
                    atPath: service == .agent
                        ? fixture.agentURL.path
                        : fixture.statusURL.path
                ),
                "known orphan plist was not removed"
            )
            try require(
                !FileManager.default.fileExists(atPath: fixture.journalURL.path),
                "registration-only recovery created a destructive cleanup journal"
            )
            let expectedLabel = service == .agent
                ? "com.wuyi.mac-face-lock-agent"
                : "com.wuyi.mac-face-lock-status"
            try require(
                fixture.commandRunner.calls.first?.arguments
                    == ["bootout", "gui/\(getuid())/\(expectedLabel)"],
                "known orphan recovery stopped the wrong service"
            )
        }
    }

    private static func testOrphanRecoveryRejectsUnknownMixedAndChangedRegistrations()
        async throws
    {
        do {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            var unknown = fixture.currentAgentDictionary(root: fixture.legacyRoot)
            unknown["Unexpected"] = "value"
            try fixture.writePlist(unknown, to: fixture.agentURL)
            try require(
                fixture.cleaner.inspectRecoverableOrphan() == nil,
                "unknown lone registration was offered for deletion"
            )
            try require(
                fixture.commandRunner.calls.isEmpty
                    && FileManager.default.fileExists(atPath: fixture.agentURL.path),
                "unknown lone registration was mutated"
            )
        }
        do {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.writeReleaseAgentPlist()
            try fixture.writeUnifiedStatusPlist()
            try require(
                fixture.cleaner.inspectRecoverableOrphan() == nil,
                "mixed release/source registrations were offered for deletion"
            )
        }
        do {
            let fixture = try LegacyCleanerFixture()
            defer { fixture.remove() }
            try fixture.writeCurrentAgentPlist()
            try fixture.write("data/preserve.bin", "preserve")
            guard let candidate = fixture.cleaner.inspectRecoverableOrphan() else {
                throw TestFailure.assertion("known orphan fixture was not recoverable")
            }
            fixture.commandRunner.resultProvider = { call, arguments in
                if call == 1 {
                    var replacement = fixture.currentAgentDictionary(
                        root: fixture.legacyRoot
                    )
                    replacement["Unexpected"] = "replacement"
                    try replaceFileAtomically(
                        at: fixture.agentURL,
                        with: plistData(replacement)
                    )
                }
                return absentServiceResult(arguments: arguments)
            }

            guard case .ambiguous =
                await fixture.cleaner.removeRecoverableOrphan(candidate) else {
                throw TestFailure.assertion(
                    "changed orphan registration was deleted"
                )
            }
            try require(
                FileManager.default.fileExists(atPath: fixture.agentURL.path),
                "changed orphan registration did not survive"
            )
            try fixture.requirePreserved("data/preserve.bin")
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
