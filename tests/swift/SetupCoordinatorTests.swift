import AppKit
import AVFoundation
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

@MainActor
private final class CoordinatorPermissionProvider: PermissionProviding {
    var cameraStatus: AVAuthorizationStatus = .authorized
    var granted: Set<SetupPermission> = [.inputMonitoring, .accessibility]
    private(set) var requested: [SetupPermission] = []
    private(set) var openedSettingsURLs: [URL] = []

    func cameraAuthorizationStatus() -> AVAuthorizationStatus {
        cameraStatus
    }

    func isGranted(_ permission: SetupPermission) -> Bool {
        granted.contains(permission)
    }

    func requiresApplicationRestart(for permission: SetupPermission) -> Bool {
        false
    }

    func requestCameraAccess() async {
        requested.append(.camera)
    }
    func requestInputMonitoringAccess() {
        requested.append(.inputMonitoring)
    }
    func requestAccessibilityAccess() {
        requested.append(.accessibility)
    }
    func requestScreenRecordingAccess() {
        requested.append(.screenRecording)
    }

    func open(_ url: URL) -> Bool {
        openedSettingsURLs.append(url)
        return true
    }
}

private final class FakeRuntimeRunner: RuntimeCommandRunning {
    var results: [RuntimeCommand: RuntimeResult] = [:]
    var events: [RuntimeCommand: [RuntimeEvent]] = [:]
    private(set) var commands: [RuntimeCommand] = []

    func run(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult {
        commands.append(command)
        var emittedEvents = events[command, default: []]
        if command == .diagnose,
           emittedEvents.contains(where: {
               $0.event == "diagnosis_complete" && $0.status == "success"
           }),
           !emittedEvents.contains(where: {
               $0.event == "diagnosis_check" && $0.check == "template"
           }) {
            emittedEvents.insert(
                RuntimeEvent(
                    schemaVersion: 1,
                    event: "diagnosis_check",
                    status: "success",
                    message: "template",
                    check: "template"
                ),
                at: 0
            )
        }
        for event in emittedEvents {
            onEvent(event)
        }
        return results[command] ?? RuntimeResult(
            exitCode: 0,
            events: emittedEvents,
            stderr: "",
            stderrTruncated: false
        )
    }
}

private final class FakeServiceHealthProvider: SetupServiceHealthProviding {
    var healthy: Bool
    private(set) var checks = 0

    init(healthy: Bool) {
        self.healthy = healthy
    }

    func isServiceHealthy() async -> Bool {
        checks += 1
        return healthy
    }
}

private final class FakeOwnerProfileInspector: OwnerProfileInspecting {
    var inspection: OwnerProfileInspection
    private(set) var inspections = 0

    init(valid: Bool = true, fingerprint: String? = "stable-owner") {
        inspection = OwnerProfileInspection(
            isValid: valid,
            fingerprint: valid ? fingerprint : nil
        )
    }

    func inspect(_ url: URL) -> OwnerProfileInspection {
        inspections += 1
        return inspection
    }
}

private final class FakeServiceManager: ServiceManaging {
    var currentStatus: ServiceStatus
    var installError: Error?
    var restartError: Error?
    private(set) var installs: [(appURL: URL, supportURL: URL)] = []
    private(set) var restartCount = 0
    private(set) var uninstallCount = 0
    private(set) var statusChecks = 0
    var suspendStatus = false
    var suspendInstall = false
    var onStatus: (() -> Void)?
    private(set) var statusStarted = false
    private(set) var installStarted = false
    private var statusContinuation: CheckedContinuation<Void, Never>?
    private var installContinuation: CheckedContinuation<Void, Never>?

    init(state: ServiceState, pid: Int32? = 42) {
        currentStatus = ServiceStatus(
            state: state,
            pid: pid,
            cameraReady: state == .healthy,
            inputMonitoringReady: state == .healthy,
            accessibilityReady: state == .healthy,
            installedProgram: nil,
            expectedProgram: "/expected/MacFaceLockAgent"
        )
    }

    func install(appURL: URL, supportURL: URL) async throws {
        if let installError {
            throw installError
        }
        installs.append((appURL, supportURL))
        installStarted = true
        if suspendInstall {
            await withCheckedContinuation { continuation in
                installContinuation = continuation
            }
        }
    }

    func status() async -> ServiceStatus {
        statusChecks += 1
        statusStarted = true
        onStatus?()
        if suspendStatus {
            await withCheckedContinuation { continuation in
                statusContinuation = continuation
            }
        }
        return currentStatus
    }

    func restart() async throws {
        if let restartError {
            throw restartError
        }
        restartCount += 1
    }

    func uninstallPreservingData() async throws {
        uninstallCount += 1
    }

    func finishStatus() {
        statusContinuation?.resume()
        statusContinuation = nil
    }

    func finishInstall() {
        installContinuation?.resume()
        installContinuation = nil
    }
}

private final class FakeLegacyInstallCleaner: LegacyInstallCleaning {
    var inspection: LegacyCleanupInspection
    var cleanResult: LegacyCleanupInspection
    var retryResult: LegacyCleanupInspection
    var suspendClean = false
    var onInspect: (() -> Void)?
    private(set) var inspectCount = 0
    private(set) var cleanedCandidates: [LegacyCleanupCandidate] = []
    private(set) var retryCount = 0
    private(set) var cleanStarted = false
    private var cleanContinuation: CheckedContinuation<Void, Never>?

    init(
        inspection: LegacyCleanupInspection,
        cleanResult: LegacyCleanupInspection = .notFound,
        retryResult: LegacyCleanupInspection = .notFound
    ) {
        self.inspection = inspection
        self.cleanResult = cleanResult
        self.retryResult = retryResult
    }

    func inspect() -> LegacyCleanupInspection {
        inspectCount += 1
        onInspect?()
        return inspection
    }

    func clean(_ candidate: LegacyCleanupCandidate) async -> LegacyCleanupInspection {
        cleanedCandidates.append(candidate)
        cleanStarted = true
        if suspendClean {
            await withCheckedContinuation { continuation in
                cleanContinuation = continuation
            }
        }
        return cleanResult
    }

    func retry() async -> LegacyCleanupInspection {
        retryCount += 1
        return retryResult
    }

    func finishClean() {
        cleanContinuation?.resume()
        cleanContinuation = nil
    }
}

private final class LateEventCancellationRunner: RuntimeCommandRunning {
    private(set) var started = false

    func run(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult {
        started = true
        return try await withTaskCancellationHandler(
            operation: {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return RuntimeResult(
                    exitCode: 0,
                    events: [],
                    stderr: "",
                    stderrTruncated: false
                )
            },
            onCancel: {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                    onEvent(
                        RuntimeEvent(
                            schemaVersion: 1,
                            event: "enrollment_progress",
                            status: "success",
                            message: "late",
                            capturedSamples: 4,
                            requiredSamples: 8
                        )
                    )
                }
            }
        )
    }
}

private final class VerificationEnrollmentOverlapRunner: RuntimeCommandRunning {
    private let replacementURL: URL
    private var verificationContinuation: CheckedContinuation<Void, Never>?
    private(set) var verificationStarted = false
    private(set) var enrollmentStarted = false

    init(replacementURL: URL) {
        self.replacementURL = replacementURL
    }

    func run(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult {
        switch command {
        case .verifyOwner:
            verificationStarted = true
            await withCheckedContinuation { continuation in
                verificationContinuation = continuation
            }
            let terminal = RuntimeEvent(
                schemaVersion: 1,
                event: "owner_verification_complete",
                status: "success",
                message: "owner",
                decision: "owner"
            )
            return RuntimeResult(
                exitCode: 0,
                events: [terminal],
                stderr: "",
                stderrTruncated: false
            )
        case .enroll:
            enrollmentStarted = true
            try Data("replacement-template".utf8).write(to: replacementURL)
            let terminal = RuntimeEvent(
                schemaVersion: 1,
                event: "enrollment_complete",
                status: "success",
                message: "complete"
            )
            onEvent(terminal)
            return RuntimeResult(
                exitCode: 0,
                events: [terminal],
                stderr: "",
                stderrTruncated: false
            )
        default:
            return RuntimeResult(
                exitCode: 20,
                events: [],
                stderr: "",
                stderrTruncated: false
            )
        }
    }

    func completeVerification() {
        verificationContinuation?.resume()
        verificationContinuation = nil
    }
}

private final class EnrollmentVerificationSerializationRunner: RuntimeCommandRunning {
    private let replacementURL: URL
    private var enrollmentContinuation: CheckedContinuation<Void, Never>?
    private(set) var enrollmentStarted = false
    private(set) var commands: [RuntimeCommand] = []

    init(replacementURL: URL) {
        self.replacementURL = replacementURL
    }

    func run(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult {
        commands.append(command)
        switch command {
        case .enroll:
            enrollmentStarted = true
            await withCheckedContinuation { continuation in
                enrollmentContinuation = continuation
            }
            try Data("replacement-template".utf8).write(to: replacementURL)
            let terminal = RuntimeEvent(
                schemaVersion: 1,
                event: "enrollment_complete",
                status: "success",
                message: "complete"
            )
            onEvent(terminal)
            return RuntimeResult(
                exitCode: 0,
                events: [terminal],
                stderr: "",
                stderrTruncated: false
            )
        case .verifyOwner:
            let terminal = RuntimeEvent(
                schemaVersion: 1,
                event: "owner_verification_complete",
                status: "success",
                message: "owner",
                decision: "owner"
            )
            return RuntimeResult(
                exitCode: 0,
                events: [terminal],
                stderr: "",
                stderrTruncated: false
            )
        default:
            return RuntimeResult(
                exitCode: 20,
                events: [],
                stderr: "",
                stderrTruncated: false
            )
        }
    }

    func completeEnrollment() {
        enrollmentContinuation?.resume()
        enrollmentContinuation = nil
    }
}

private final class CancellationEOFWindowRunner: RuntimeCommandRunning {
    private var eofContinuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var runCount = 0

    func run(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult {
        runCount += 1
        if runCount > 1 {
            return RuntimeResult(
                exitCode: 10,
                events: [
                    RuntimeEvent(
                        schemaVersion: 1,
                        event: "camera_unavailable",
                        status: "error",
                        message: "camera"
                    ),
                ],
                stderr: "",
                stderrTruncated: false
            )
        }
        started = true
        return try await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    eofContinuation = continuation
                }
                try Task.checkCancellation()
                return RuntimeResult(
                    exitCode: 0,
                    events: [],
                    stderr: "",
                    stderrTruncated: false
                )
            },
            onCancel: {
                onEvent(
                    RuntimeEvent(
                        schemaVersion: 1,
                        event: "enrollment_progress",
                        status: "success",
                        message: "during termination",
                        capturedSamples: 7,
                        requiredSamples: 8
                    )
                )
            }
        )
    }

    func deliverEOF() {
        eofContinuation?.resume()
        eofContinuation = nil
    }
}

private final class SerializedDiagnosisRunner: RuntimeCommandRunning {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var commands: [RuntimeCommand] = []

    func run(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult {
        commands.append(command)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        activeCount -= 1
        let terminal = RuntimeEvent(
            schemaVersion: 1,
            event: "diagnosis_complete",
            status: "success",
            message: "complete"
        )
        return RuntimeResult(
            exitCode: 0,
            events: [
                RuntimeEvent(
                    schemaVersion: 1,
                    event: "diagnosis_check",
                    status: "success",
                    message: "template",
                    check: "template"
                ),
                terminal,
            ],
            stderr: "",
            stderrTruncated: false
        )
    }

    func completeNext() {
        guard !continuations.isEmpty else {
            return
        }
        continuations.removeFirst().resume()
    }
}

private final class EnrollmentQueueCancellationRunner: RuntimeCommandRunning {
    private var diagnosisContinuation: CheckedContinuation<Void, Never>?
    private(set) var diagnosisStarted = false
    private(set) var enrollmentCommands = 0

    func run(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult {
        switch command {
        case .diagnose:
            diagnosisStarted = true
            await withCheckedContinuation { continuation in
                diagnosisContinuation = continuation
            }
            return RuntimeResult(
                exitCode: 0,
                events: [
                    RuntimeEvent(
                        schemaVersion: 1,
                        event: "diagnosis_check",
                        status: "success",
                        message: "template",
                        check: "template"
                    ),
                    RuntimeEvent(
                        schemaVersion: 1,
                        event: "diagnosis_complete",
                        status: "success",
                        message: "complete"
                    ),
                ],
                stderr: "",
                stderrTruncated: false
            )
        case .enroll:
            enrollmentCommands += 1
            let terminal = RuntimeEvent(
                schemaVersion: 1,
                event: "enrollment_complete",
                status: "success",
                message: "complete"
            )
            onEvent(terminal)
            return RuntimeResult(
                exitCode: 0,
                events: [terminal],
                stderr: "",
                stderrTruncated: false
            )
        default:
            return RuntimeResult(
                exitCode: 20,
                events: [],
                stderr: "",
                stderrTruncated: false
            )
        }
    }

    func completeDiagnosis() {
        diagnosisContinuation?.resume()
        diagnosisContinuation = nil
    }
}

private final class EnrollmentChildStartWindowRunner: RuntimeCommandRunning {
    private var firstEnrollmentContinuation: CheckedContinuation<Void, Never>?
    private(set) var firstEnrollmentEntered = false
    private(set) var enrollmentEntries = 0
    private(set) var cameraStarts = 0

    func run(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult {
        guard command == .enroll else {
            return RuntimeResult(
                exitCode: 0,
                events: [],
                stderr: "",
                stderrTruncated: false
            )
        }
        enrollmentEntries += 1
        if enrollmentEntries == 1 {
            firstEnrollmentEntered = true
            await withCheckedContinuation { continuation in
                firstEnrollmentContinuation = continuation
            }
            try Task.checkCancellation()
        }
        cameraStarts += 1
        let terminal = RuntimeEvent(
            schemaVersion: 1,
            event: "enrollment_complete",
            status: "success",
            message: "complete"
        )
        onEvent(terminal)
        return RuntimeResult(
            exitCode: 0,
            events: [terminal],
            stderr: "",
            stderrTruncated: false
        )
    }

    func releaseFirstEnrollmentStartWindow() {
        firstEnrollmentContinuation?.resume()
        firstEnrollmentContinuation = nil
    }
}

private struct NumpyHeaderCorpusCase: Decodable {
    let name: String
    let version: Int
    let header: String
    let headerLength: Int
    let payloadRows: Int
    let expected: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case header
        case headerLength = "header_length"
        case payloadRows = "payload_rows"
        case expected
    }
}

private struct CoordinatorFixture {
    let root: URL
    let localStore: LocalJSONStore
    let setupStore: SetupStore
    let environment: AppEnvironment

    init(mode: AppEnvironmentMode = .release) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-face-lock-coordinator-\(UUID().uuidString)")
        let dataURL = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        localStore = LocalJSONStore(resourcesURL: root, dataURL: dataURL)
        setupStore = try SetupStore(localStore: localStore, mode: mode)
        environment = AppEnvironment(
            mode: mode,
            resourcesURL: root,
            supportURL: root,
            configURL: root.appendingPathComponent("config/config.json"),
            dataURL: dataURL,
            logsURL: root.appendingPathComponent("logs"),
            runtimeExecutableURL: root.appendingPathComponent("runtime")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@main
@MainActor
struct SetupCoordinatorTests {
    static func main() async throws {
        try testReleaseCoordinatorStartsDurablyDisabled()
        try await testBlockedTransitionsClearPublishedReadinessImmediately()
        try await testCompletedMarkerResetsOnRelaunch()
        try await testCompletedMarkerRetriesFailedResetOnNextLaunch()
        try await testRefreshInspectionBarrierRunsOnceBeforeServiceStatus()
        try await testBlockedReentryCannotPublishStatusInstallOrEnable()
        try await testLegacyCleanupSourceAndReleaseBoundaries()
        try await testLegacyInspectionMapsEveryResult()
        try await testLegacyCleanupPreparationAndActions()
        try await testCompletedCleanupRequiresFreshEnrollment()
        try await testServiceManagerIsUntouchedForEveryBlockedCleanupState()
        try await testCoordinatesProgressDiagnosisAndNoLockOwnerVerification()
        try await testMapsRuntimeExitCodesToChineseRepairs()
        try await testFailedReenrollmentPreservesExistingOwnerProfile()
        try await testSuccessfulEnrollmentRequiresSuccessfulTerminalStatus()
        try await testCancellationIgnoresLateProgress()
        try await testCancellationInvalidatesCallbacksBeforeRuntimeEOF()
        try await testVerificationDoesNotLaunchDuringActiveEnrollment()
        try await testSuccessfulEnrollmentClearsActiveEnrollmentRefusal()
        try await testVerificationCannotPassAfterEnrollmentReplacesProfile()
        try await testReleaseDiagnosisInstallsAndUsesAgentOwnedServiceHealth()
        try await testVisibleAppGrantsCannotOverrideUnhealthyAgentPermissions()
        try await testSourceModePreservesExistingServiceHealthBoundary()
        try await testEnableProtectionRefusesWhenAnyGateIsFalse()
        try await testEnableProtectionRechecksReleaseServiceAfterDiagnosis()
        try await testEnableProtectionRechecksSourceServiceProvider()
        try await testRestoresSafeStepAndForwardsPermissionActions()
        try testUnsafePersistedStepFallsBackToLastSatisfiedGate()
        try await testOperationalServiceRepairActionsUseServiceManager()
        try await testCompletedRecordDoesNotFabricateLiveRuntimeGates()
        try await testEnableProtectionReprobesRevokedPermissionAndFallsBack()
        try await testCompletedAuthorizationRefreshFallsBackAfterRevocation()
        try await testCompletedInstallKeepsRecoverySurfaceWhenServiceIsUnhealthy()
        try await testCancelImmediateRetryWaitsForRuntimeCleanup()
        try await testServiceErrorsAreSanitizedBeforePublishing()
        try testOpenLogsReportsCustomerSafeFailure()
        try await testHealthyCompletedRelaunchAndForegroundStayReadyWithoutRuntime()
        try await testFreshPreparationPassiveRefreshRunsNoRuntimeCommand()
        try await testFreshReleaseContinuesThroughRequiredEnrollment()
        try await testFreshReleaseWithExistingOwnerStillRequiresEnrollment()
        try await testRuntimeDiagnosticsAreSerialized()
        try testStrictStaticOwnerProfileInspection()
        try testSharedNumpyHeaderCorpusMatchesSwiftInspector()
        try testAdversarialOwnerProfilesAreRejectedWithoutCoordinatorCrash()
        try await testQueuedEnrollmentCancellationNeverStartsRuntime()
        try await testParentCancellationPropagatesToEnrollmentChildAtStart()
        try await testCameraOnlyDiagnosisKeepsValidOwnerProfile()
        try await testCompletedCameraRevocationRecoveryPreservesHistoryAndSkipsEnrollment()
        print("Setup coordinator tests passed")
    }

    private static func event(
        _ name: String,
        status: String = "success",
        capturedSamples: Int? = nil,
        requiredSamples: Int? = nil,
        check: String? = nil,
        decision: String? = nil
    ) -> RuntimeEvent {
        RuntimeEvent(
            schemaVersion: 1,
            event: name,
            status: status,
            message: name,
            capturedSamples: capturedSamples,
            requiredSamples: requiredSamples,
            check: check,
            failedChecks: nil,
            decision: decision
        )
    }

    private static func completedRecord() -> OnboardingRecord {
        OnboardingRecord(
            currentStep: .completion,
            completedSteps: SetupStep.allCases,
            completedAt: "2026-07-18T00:00:00Z",
            appVersion: "0.1.0-beta",
            ownerProfileFingerprint: "stable-owner",
            requiresOwnerReverification: false
        )
    }

    private static func testReleaseCoordinatorStartsDurablyDisabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mac-face-lock-initial-disable-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let dataURL = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dataURL,
            withIntermediateDirectories: true
        )
        let localStore = LocalJSONStore(resourcesURL: root, dataURL: dataURL)
        try localStore.writeOnboarding(completedRecord())
        _ = try localStore.writeControl(enabled: true)
        let setupStore = try SetupStore(localStore: localStore, mode: .release)
        let environment = AppEnvironment(
            mode: .release,
            resourcesURL: root,
            supportURL: root,
            configURL: root.appendingPathComponent("config/config.json"),
            dataURL: dataURL,
            logsURL: root.appendingPathComponent("logs"),
            runtimeExecutableURL: root.appendingPathComponent("runtime")
        )

        let subject = SetupCoordinator(
            environment: environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: setupStore,
            localStore: localStore,
            serviceManager: FakeServiceManager(state: .healthy),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )

        try require(
            subject.legacyCleanupState == .unchecked,
            "release coordinator did not start unchecked"
        )
        try require(
            !localStore.readControl().protectionEnabled,
            "release coordinator exposed enabled control before async inspection"
        )
        try require(
            !subject.isLiveReady,
            "unchecked release coordinator published live readiness"
        )
    }

    private static func testBlockedTransitionsClearPublishedReadinessImmediately()
        async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try fixture.setupStore.save(completedRecord())
        let cleaner = FakeLegacyInstallCleaner(inspection: .notFound)
        let service = FakeServiceManager(state: .healthy)
        let subject = coordinator(
            fixture: fixture,
            cleaner: cleaner,
            serviceManager: service,
            ownerProfileInspector: FakeOwnerProfileInspector()
        )
        await subject.refreshLiveReadiness()
        try require(subject.serviceStatus != nil, "fixture did not publish service status")
        _ = try fixture.localStore.writeControl(enabled: true)

        subject.applyLegacyInspectionForTesting(.ambiguous("late legacy state"))

        try require(
            subject.legacyCleanupState == .ambiguous("late legacy state"),
            "blocked transition did not publish its cleanup state"
        )
        try require(
            subject.serviceStatus == nil
                && subject.checks[.serviceHealth] == false
                && !subject.isLiveReady,
            "blocked transition retained service or readiness publication"
        )
        try require(
            !fixture.localStore.readControl().protectionEnabled,
            "blocked transition did not durably disable protection"
        )
    }

    private static func testCompletedMarkerResetsOnRelaunch() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try fixture.setupStore.save(completedRecord())
        let cleaner = FakeLegacyInstallCleaner(inspection: .completed)
        let service = FakeServiceManager(state: .healthy)
        let subject = coordinator(
            fixture: fixture,
            cleaner: cleaner,
            serviceManager: service,
            ownerProfileInspector: FakeOwnerProfileInspector()
        )

        await subject.refreshLiveReadiness()

        try require(cleaner.inspectCount == 1, "completion marker was not inspected once")
        try require(
            subject.legacyCleanupState == .completed
                && !subject.hasCompletedOnboarding
                && subject.currentStep == .preparation,
            "completion marker did not reset stale completed onboarding"
        )
        try require(
            service.statusChecks == 1,
            "service access did not wait for successful completion reset"
        )
    }

    private static func testCompletedMarkerRetriesFailedResetOnNextLaunch()
        async throws {
        let fixture = try CoordinatorFixture()
        defer {
            _ = chmod(fixture.environment.dataURL.path, 0o700)
            fixture.remove()
        }
        try fixture.setupStore.save(completedRecord())
        guard chmod(fixture.environment.dataURL.path, 0o500) == 0 else {
            throw TestFailure.assertion("could not make onboarding directory read-only")
        }
        let firstService = FakeServiceManager(state: .healthy)
        let first = coordinator(
            fixture: fixture,
            cleaner: FakeLegacyInstallCleaner(inspection: .completed),
            serviceManager: firstService,
            ownerProfileInspector: FakeOwnerProfileInspector()
        )

        await first.refreshLiveReadiness()

        try require(
            first.legacyCleanupState == .cleanupIncomplete(
                "旧版清理已完成，但无法重置首次设置状态。"
            ),
            "failed completion reset did not remain blocked"
        )
        try require(
            firstService.statusChecks == 0
                && fixture.setupStore.record.isComplete,
            "failed completion reset crossed service gate or erased retry evidence"
        )

        guard chmod(fixture.environment.dataURL.path, 0o700) == 0 else {
            throw TestFailure.assertion("could not restore onboarding directory")
        }
        let relaunchedStore = try SetupStore(
            localStore: fixture.localStore,
            mode: .release
        )
        let relaunchedService = FakeServiceManager(state: .healthy)
        let relaunched = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: relaunchedStore,
            localStore: fixture.localStore,
            serviceManager: relaunchedService,
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .completed),
            applicationURL: URL(fileURLWithPath: "/Applications/Mac Face Lock.app"),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )

        await relaunched.refreshLiveReadiness()

        try require(
            relaunched.legacyCleanupState == .completed
                && !relaunched.hasCompletedOnboarding
                && relaunched.currentStep == .preparation,
            "next launch did not retry and complete onboarding reset"
        )
        try require(
            relaunchedService.statusChecks == 1,
            "next launch did not delay service access until reset succeeded"
        )
    }

    private static func testRefreshInspectionBarrierRunsOnceBeforeServiceStatus()
        async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        var events: [String] = []
        let cleaner = FakeLegacyInstallCleaner(inspection: .notFound)
        cleaner.onInspect = { events.append("inspect") }
        let service = FakeServiceManager(state: .healthy)
        service.onStatus = { events.append("status") }
        let subject = coordinator(
            fixture: fixture,
            cleaner: cleaner,
            serviceManager: service
        )

        async let liveRefresh: Void = subject.refreshLiveReadiness()
        async let authorizationRefresh: Void =
            subject.refreshCurrentAuthorizationStatus()
        _ = await (liveRefresh, authorizationRefresh)

        try require(
            cleaner.inspectCount == 1,
            "concurrent initial refreshes duplicated cleanup inspection"
        )
        try require(
            events.first == "inspect"
                && events.filter { $0 == "status" }.count == 2,
            "refresh reached service status before the inspection barrier"
        )
    }

    private static func testBlockedReentryCannotPublishStatusInstallOrEnable()
        async throws {
        try await assertBlockedReentryDropsStatus()
        try await assertBlockedReentryStopsAfterInstall()
        try await assertBlockedReentryCannotEnableControl()
    }

    private static func assertBlockedReentryDropsStatus() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let cleaner = FakeLegacyInstallCleaner(inspection: .notFound)
        let service = FakeServiceManager(state: .healthy)
        service.suspendStatus = true
        let subject = coordinator(
            fixture: fixture,
            cleaner: cleaner,
            serviceManager: service,
            ownerProfileInspector: FakeOwnerProfileInspector()
        )
        let refresh = Task { await subject.refreshLiveReadiness() }
        for _ in 0..<40 where !service.statusStarted {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        cleaner.inspection = .ambiguous("repeated inspection")
        await subject.inspectLegacyInstall()
        try require(
            cleaner.inspectCount == 1
                && subject.legacyCleanupState == .notRequired,
            "allowed cleanup state was inspected repeatedly"
        )
        subject.applyLegacyInspectionForTesting(.ambiguous("blocked during status"))
        service.finishStatus()
        await refresh.value

        try require(
            subject.serviceStatus == nil
                && subject.checks[.serviceHealth] == false
                && !subject.isLiveReady,
            "suspended status published after cleanup became blocked"
        )
        try require(
            !fixture.localStore.readControl().protectionEnabled,
            "suspended status re-enabled control after cleanup became blocked"
        )
    }

    private static func assertBlockedReentryStopsAfterInstall() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [event("diagnosis_complete")]
        let service = FakeServiceManager(state: .healthy)
        service.suspendInstall = true
        let subject = coordinator(
            fixture: fixture,
            cleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            serviceManager: service,
            runtimeRunner: runner,
            ownerProfileInspector: FakeOwnerProfileInspector()
        )
        await subject.inspectLegacyInstall()
        let diagnosis = Task { await subject.runDiagnosis() }
        for _ in 0..<40 where !service.installStarted {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        subject.applyLegacyInspectionForTesting(.cleanupIncomplete("blocked during install"))
        service.finishInstall()
        await diagnosis.value

        try require(
            service.statusChecks == 0 && subject.serviceStatus == nil,
            "suspended install crossed the blocked gate to status publication"
        )
    }

    private static func assertBlockedReentryCannotEnableControl() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [event("diagnosis_complete")]
        runner.events[.verifyOwner] = [
            event("owner_verification_complete", decision: "owner"),
        ]
        let service = FakeServiceManager(state: .healthy)
        service.suspendStatus = true
        let subject = coordinator(
            fixture: fixture,
            cleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            serviceManager: service,
            runtimeRunner: runner,
            ownerProfileInspector: FakeOwnerProfileInspector()
        )
        await subject.inspectLegacyInstall()
        let enable = Task {
            do {
                try await subject.enableProtection()
                return true
            } catch {
                return false
            }
        }
        for _ in 0..<40 where !service.statusStarted {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        subject.applyLegacyInspectionForTesting(.ambiguous("blocked during enable"))
        service.finishStatus()
        let enabled = await enable.value

        try require(!enabled, "enable succeeded after cleanup became blocked")
        try require(
            !fixture.localStore.readControl().protectionEnabled
                && !subject.hasCompletedOnboarding
                && !subject.isLiveReady,
            "suspended enable published completion or enabled control after block"
        )
    }

    private static func legacyCandidate(
        root: URL = URL(fileURLWithPath: "/tmp/legacy-mac-face-lock")
    ) -> LegacyCleanupCandidate {
        LegacyCleanupCandidate(
            rootURL: root,
            rootIdentity: SecureFileIdentity(device: 1, inode: 2),
            agentPlistIdentity: SecureFileIdentity(device: 1, inode: 3),
            statusPlistIdentity: SecureFileIdentity(device: 1, inode: 4)
        )
    }

    private static func coordinator(
        fixture: CoordinatorFixture,
        cleaner: LegacyInstallCleaning?,
        serviceManager: ServiceManaging? = nil,
        runtimeRunner: RuntimeCommandRunning = FakeRuntimeRunner(),
        ownerProfileInspector: OwnerProfileInspecting = FakeOwnerProfileInspector(valid: false)
    ) -> SetupCoordinator {
        SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runtimeRunner,
            serviceManager: serviceManager,
            legacyInstallCleaner: cleaner,
            applicationURL: URL(fileURLWithPath: "/Applications/Mac Face Lock.app"),
            ownerProfileInspector: ownerProfileInspector
        )
    }

    private static func testLegacyCleanupSourceAndReleaseBoundaries() async throws {
        let sourceFixture = try CoordinatorFixture(mode: .source)
        defer { sourceFixture.remove() }
        let sourceCleaner = FakeLegacyInstallCleaner(
            inspection: .confirmed(legacyCandidate())
        )
        let sourceCoordinator = coordinator(
            fixture: sourceFixture,
            cleaner: sourceCleaner
        )

        try require(
            sourceCoordinator.legacyCleanupState == .notRequired,
            "source mode did not start with cleanup not required"
        )
        await sourceCoordinator.inspectLegacyInstall()
        _ = await sourceCoordinator.prepareForSetup()
        try require(
            sourceCleaner.inspectCount == 0
                && sourceCleaner.cleanedCandidates.isEmpty
                && sourceCleaner.retryCount == 0,
            "source mode instantiated or called the legacy cleaner boundary"
        )

        let releaseFixture = try CoordinatorFixture()
        defer { releaseFixture.remove() }
        let releaseCoordinator = coordinator(
            fixture: releaseFixture,
            cleaner: FakeLegacyInstallCleaner(inspection: .notFound)
        )
        try require(
            releaseCoordinator.legacyCleanupState == .unchecked,
            "release mode did not start with cleanup unchecked"
        )
        try require(
            releaseCoordinator.requiresLegacyCleanupAttention,
            "unchecked release cleanup did not require attention"
        )
    }

    private static func testLegacyInspectionMapsEveryResult() async throws {
        let cases: [(LegacyCleanupInspection, LegacyCleanupState)] = [
            (.notFound, .notRequired),
            (.confirmed(legacyCandidate()), .confirmationRequired),
            (.ambiguous("ambiguous"), .ambiguous("ambiguous")),
            (.cleanupIncomplete("incomplete"), .cleanupIncomplete("incomplete")),
        ]

        for (inspection, expectedState) in cases {
            let fixture = try CoordinatorFixture()
            defer { fixture.remove() }
            let cleaner = FakeLegacyInstallCleaner(inspection: inspection)
            let subject = coordinator(fixture: fixture, cleaner: cleaner)
            _ = try fixture.localStore.writeControl(enabled: true)

            await subject.inspectLegacyInstall()

            try require(
                subject.legacyCleanupState == expectedState,
                "inspection \(inspection) mapped to the wrong cleanup state"
            )
            try require(cleaner.inspectCount == 1, "inspection was not invoked exactly once")
            if expectedState != .notRequired {
                try require(
                    !fixture.localStore.readControl().protectionEnabled,
                    "blocked inspection \(inspection) did not durably disable protection"
                )
            }
        }
    }

    private static func testLegacyCleanupPreparationAndActions() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let candidate = legacyCandidate(root: fixture.root.appendingPathComponent("legacy"))
        let cleaner = FakeLegacyInstallCleaner(
            inspection: .confirmed(candidate),
            cleanResult: .notFound
        )
        let subject = coordinator(fixture: fixture, cleaner: cleaner)

        let uncheckedPreparation = await subject.prepareForSetup()
        try require(!uncheckedPreparation, "unchecked cleanup advanced preparation")
        try require(
            subject.legacyCleanupState == .confirmationRequired,
            "unchecked preparation did not inspect the legacy install"
        )
        let confirmationPreparation = await subject.prepareForSetup()
        try require(!confirmationPreparation, "confirmation-required cleanup advanced preparation")

        subject.cancelLegacyCleanup()
        try require(
            cleaner.cleanedCandidates.isEmpty && cleaner.retryCount == 0,
            "cancel called the legacy cleaner"
        )
        let cancelledPreparation = await subject.prepareForSetup()
        try require(
            !cancelledPreparation,
            "cancelled cleanup advanced preparation"
        )

        let cleaned = await subject.confirmLegacyCleanup()
        try require(cleaned, "confirmed cleanup did not complete")
        try require(
            cleaner.cleanedCandidates == [candidate],
            "confirm did not clean only the privately stored candidate"
        )
        try require(cleaner.retryCount == 0, "confirm invoked retry")

        let incompleteFixture = try CoordinatorFixture()
        defer { incompleteFixture.remove() }
        let incompleteCleaner = FakeLegacyInstallCleaner(
            inspection: .cleanupIncomplete("partial"),
            retryResult: .notFound
        )
        let incompleteSubject = coordinator(
            fixture: incompleteFixture,
            cleaner: incompleteCleaner
        )
        await incompleteSubject.inspectLegacyInstall()
        let incompletePreparation = await incompleteSubject.prepareForSetup()
        try require(
            !incompletePreparation,
            "incomplete cleanup advanced preparation"
        )
        let retried = await incompleteSubject.retryLegacyCleanup()
        try require(retried, "cleanup retry did not complete")
        try require(incompleteCleaner.retryCount == 1, "retry was not invoked exactly once")
        try require(
            incompleteCleaner.cleanedCandidates.isEmpty,
            "retry invoked clean with a candidate"
        )

        let ambiguousFixture = try CoordinatorFixture()
        defer { ambiguousFixture.remove() }
        let ambiguousCleaner = FakeLegacyInstallCleaner(
            inspection: .ambiguous("unknown")
        )
        let ambiguousSubject = coordinator(
            fixture: ambiguousFixture,
            cleaner: ambiguousCleaner
        )
        await ambiguousSubject.inspectLegacyInstall()
        let ambiguousPreparation = await ambiguousSubject.prepareForSetup()
        try require(
            !ambiguousPreparation,
            "ambiguous cleanup advanced preparation"
        )
        let ambiguousConfirmation = await ambiguousSubject.confirmLegacyCleanup()
        try require(
            !ambiguousConfirmation,
            "ambiguous cleanup accepted confirmation"
        )
        try require(
            ambiguousCleaner.cleanedCandidates.isEmpty,
            "ambiguous cleanup retained and cleaned a candidate"
        )

        let cleaningFixture = try CoordinatorFixture()
        defer { cleaningFixture.remove() }
        let cleaningCleaner = FakeLegacyInstallCleaner(
            inspection: .confirmed(legacyCandidate()),
            cleanResult: .notFound
        )
        cleaningCleaner.suspendClean = true
        let cleaningSubject = coordinator(
            fixture: cleaningFixture,
            cleaner: cleaningCleaner
        )
        await cleaningSubject.inspectLegacyInstall()
        _ = try cleaningFixture.localStore.writeControl(enabled: true)
        let cleaningTask = Task {
            await cleaningSubject.confirmLegacyCleanup()
        }
        for _ in 0..<40 where !cleaningCleaner.cleanStarted {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try require(
            cleaningSubject.legacyCleanupState == .cleaning
                && !cleaningFixture.localStore.readControl().protectionEnabled,
            "cleaning transition did not durably disable protection"
        )
        _ = try cleaningFixture.localStore.writeControl(enabled: true)
        cleaningSubject.applyLegacyInspectionForTesting(
            .cleanupIncomplete("re-entered while cleaning")
        )
        try require(
            cleaningSubject.legacyCleanupState
                == .cleanupIncomplete("re-entered while cleaning"),
            "cleanup re-entry did not publish the blocked state"
        )
        try require(
            !cleaningFixture.localStore.readControl().protectionEnabled,
            "cleanup re-entry did not durably disable protection"
        )
        let cleaningPreparation = await cleaningSubject.prepareForSetup()
        try require(
            !cleaningPreparation,
            "cleaning state advanced preparation"
        )
        cleaningCleaner.finishClean()
        _ = await cleaningTask.value
    }

    private static func testCompletedCleanupRequiresFreshEnrollment() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try fixture.setupStore.save(
            OnboardingRecord(
                currentStep: .completion,
                completedSteps: SetupStep.allCases,
                completedAt: "2026-07-18T00:00:00Z",
                appVersion: "0.1.0-beta",
                ownerProfileFingerprint: "legacy-owner",
                requiresOwnerReverification: false
            )
        )
        try Data().write(to: fixture.environment.runtimeExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.environment.runtimeExecutableURL.path
        )
        let cleaner = FakeLegacyInstallCleaner(
            inspection: .confirmed(legacyCandidate()),
            cleanResult: .notFound
        )
        let subject = coordinator(
            fixture: fixture,
            cleaner: cleaner,
            ownerProfileInspector: FakeOwnerProfileInspector(
                valid: true,
                fingerprint: "legacy-owner"
            )
        )

        await subject.inspectLegacyInstall()
        let cleanupCompleted = await subject.confirmLegacyCleanup()
        try require(cleanupCompleted, "legacy cleanup did not complete")
        try require(
            !subject.hasCompletedOnboarding && subject.currentStep == .preparation,
            "completed cleanup preserved a completed onboarding record"
        )
        let prepared = await subject.prepareForSetup()
        try require(prepared, "fresh preparation did not advance")
        let continued = await subject.continueFromPermissions()
        try require(
            continued,
            "fresh permissions did not advance"
        )
        try require(
            subject.currentStep == .enrollment,
            "completed cleanup did not require fresh enrollment"
        )
    }

    private static func testServiceManagerIsUntouchedForEveryBlockedCleanupState()
        async throws {
        try await assertUncheckedDirectServicePathsAreUntouched()
        try await assertServiceManagerUntouched(
            inspection: .confirmed(legacyCandidate()),
            expectedState: .confirmationRequired
        )
        try await assertServiceManagerUntouched(
            inspection: .ambiguous("unknown"),
            expectedState: .ambiguous("unknown")
        )
        try await assertServiceManagerUntouched(
            inspection: .cleanupIncomplete("partial"),
            expectedState: .cleanupIncomplete("partial")
        )

        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let cleaner = FakeLegacyInstallCleaner(
            inspection: .confirmed(legacyCandidate()),
            cleanResult: .notFound
        )
        cleaner.suspendClean = true
        let service = FakeServiceManager(state: .healthy)
        let subject = coordinator(
            fixture: fixture,
            cleaner: cleaner,
            serviceManager: service
        )
        await subject.inspectLegacyInstall()
        let cleaningTask = Task {
            await subject.confirmLegacyCleanup()
        }
        for _ in 0..<40 where !cleaner.cleanStarted {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await exerciseEveryServicePath(on: subject)
        try require(
            subject.legacyCleanupState == .cleaning,
            "service-path exercise changed the cleaning state"
        )
        try require(
            service.statusChecks == 0
                && service.restartCount == 0
                && service.installs.isEmpty
                && service.uninstallCount == 0,
            "a service path crossed the cleaning gate"
        )
        cleaner.finishClean()
        _ = await cleaningTask.value
    }

    private static func assertUncheckedDirectServicePathsAreUntouched()
        async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let service = FakeServiceManager(state: .healthy)
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [event("diagnosis_complete")]
        let subject = coordinator(
            fixture: fixture,
            cleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            serviceManager: service,
            runtimeRunner: runner
        )

        await subject.restartService()
        await subject.reinstallService()
        await subject.runDiagnosis()

        try require(
            subject.legacyCleanupState == .unchecked,
            "direct service actions advanced unchecked inspection"
        )
        try require(
            service.statusChecks == 0
                && service.restartCount == 0
                && service.installs.isEmpty
                && service.uninstallCount == 0,
            "a direct service action crossed the unchecked gate"
        )
    }

    private static func assertServiceManagerUntouched(
        inspection: LegacyCleanupInspection?,
        expectedState: LegacyCleanupState
    ) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let cleaner = FakeLegacyInstallCleaner(
            inspection: inspection ?? .notFound
        )
        let service = FakeServiceManager(state: .healthy)
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [event("diagnosis_complete")]
        let subject = coordinator(
            fixture: fixture,
            cleaner: cleaner,
            serviceManager: service,
            runtimeRunner: runner
        )
        if inspection != nil {
            await subject.inspectLegacyInstall()
        }
        try require(
            subject.legacyCleanupState == expectedState,
            "fixture did not reach expected blocked cleanup state"
        )

        try await exerciseEveryServicePath(on: subject)

        try require(service.statusChecks == 0, "status read crossed cleanup gate")
        try require(service.restartCount == 0, "restart crossed cleanup gate")
        try require(service.installs.isEmpty, "install crossed cleanup gate")
        try require(service.uninstallCount == 0, "uninstall crossed cleanup gate")
    }

    private static func exerciseEveryServicePath(
        on subject: SetupCoordinator
    ) async throws {
        await subject.refreshLiveReadiness()
        await subject.refreshCurrentAuthorizationStatus()
        await subject.restartService()
        await subject.reinstallService()
        await subject.runDiagnosis()
        do {
            try await subject.enableProtection()
        } catch {
            // The cleanup gate must leave protection disabled.
        }
    }

    private static func testCoordinatesProgressDiagnosisAndNoLockOwnerVerification() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let runner = FakeRuntimeRunner()
        runner.events[.enroll] = [
            event("enrollment_started"),
            event("enrollment_progress", capturedSamples: 4, requiredSamples: 8),
            event("enrollment_complete"),
        ]
        runner.events[.diagnose] = [
            event("diagnosis_check", check: "camera"),
            event("diagnosis_complete"),
        ]
        runner.events[.verifyOwner] = [
            event("owner_verification_complete", decision: "owner"),
        ]
        try Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]).write(
            to: fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        let permissionCenter = PermissionCenter(provider: CoordinatorPermissionProvider())
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: permissionCenter,
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.refreshPermissions()
        await coordinator.startEnrollment()
        try require(coordinator.progress == 1, "successful enrollment did not publish completion")
        try require(
            fixture.setupStore.record.completedSteps.contains(.enrollment),
            "successful enrollment was not persisted through SetupStore"
        )
        await coordinator.runDiagnosis()
        await coordinator.verifyOwnerWithoutLocking()

        try require(
            runner.commands == [.enroll, .diagnose, .verifyOwner],
            "coordinator invoked an unexpected runtime command"
        )
        try require(
            !runner.commands.contains(.agent),
            "owner verification attempted to run the locking agent"
        )
        try require(coordinator.checks[.diagnosis] == true, "diagnosis did not pass readiness")
        try require(coordinator.checks[.ownerTest] == true, "owner test did not pass readiness")
    }

    private static func testMapsRuntimeExitCodesToChineseRepairs() async throws {
        let expectedFragments: [(Int32, String)] = [
            (2, "重新安装"),
            (10, "摄像头"),
            (11, "重新录入"),
            (12, "光线"),
            (20, "运行组件"),
            (99, "代码 99"),
        ]

        for (exitCode, fragment) in expectedFragments {
            let fixture = try CoordinatorFixture()
            defer { fixture.remove() }
            let runner = FakeRuntimeRunner()
            runner.results[.diagnose] = RuntimeResult(
                exitCode: exitCode,
                events: [],
                stderr: "private runtime detail",
                stderrTruncated: false
            )
            let coordinator = SetupCoordinator(
                environment: fixture.environment,
                permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
                setupStore: fixture.setupStore,
                localStore: fixture.localStore,
                runtimeRunner: runner,
                legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
                serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
            )

            await coordinator.inspectLegacyInstall()
            await coordinator.runDiagnosis()

            try require(
                coordinator.currentError?.contains(fragment) == true,
                "exit \(exitCode) did not map to its concise Chinese repair"
            )
            try require(
                coordinator.currentError?.contains("private runtime detail") == false,
                "raw stderr leaked into the user-facing repair"
            )
        }
    }

    private static func testEnableProtectionRefusesWhenAnyGateIsFalse() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        _ = try fixture.localStore.writeControl(enabled: false)
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: FakeRuntimeRunner(),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            serviceHealthProvider: FakeServiceHealthProvider(healthy: false)
        )
        await coordinator.inspectLegacyInstall()
        await coordinator.refreshPermissions()

        do {
            try await coordinator.enableProtection()
            throw TestFailure.assertion("protection enabled with a required gate false")
        } catch is SetupCoordinatorError {
            // Expected.
        }

        try require(
            !fixture.localStore.readControl().protectionEnabled,
            "readiness refusal still wrote protection enabled"
        )
        try require(
            coordinator.currentError?.contains("尚未完成") == true,
            "readiness refusal did not publish an actionable error"
        )
    }

    private static func testEnableProtectionRechecksReleaseServiceAfterDiagnosis() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try Data("owner".utf8).write(
            to: fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        _ = try fixture.localStore.writeControl(enabled: false)
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [event("diagnosis_complete")]
        runner.events[.verifyOwner] = [
            event("owner_verification_complete", decision: "owner"),
        ]
        let serviceManager = FakeServiceManager(state: .healthy)
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceManager: serviceManager,
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound)
        )
        await coordinator.inspectLegacyInstall()
        await coordinator.refreshPermissions()
        await coordinator.runDiagnosis()
        await coordinator.verifyOwnerWithoutLocking()
        try require(
            coordinator.readiness.canEnableProtection,
            "fixture did not reach ready state before service death"
        )
        serviceManager.currentStatus = ServiceStatus(
            state: .unhealthy,
            pid: 42,
            cameraReady: false,
            inputMonitoringReady: false,
            accessibilityReady: false,
            installedProgram: nil,
            expectedProgram: "/expected/MacFaceLockAgent"
        )

        do {
            try await coordinator.enableProtection()
            throw TestFailure.assertion(
                "protection enabled after the diagnosed release service died"
            )
        } catch is SetupCoordinatorError {
            // Expected.
        }

        try require(
            !fixture.localStore.readControl().protectionEnabled,
            "release service death still wrote protection enabled"
        )
        try require(
            coordinator.checks[.serviceHealth] == false,
            "release service death did not refresh readiness"
        )
    }

    private static func testEnableProtectionRechecksSourceServiceProvider() async throws {
        let fixture = try CoordinatorFixture(mode: .source)
        defer { fixture.remove() }
        try Data("owner".utf8).write(
            to: fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        _ = try fixture.localStore.writeControl(enabled: false)
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [event("diagnosis_complete")]
        runner.events[.verifyOwner] = [
            event("owner_verification_complete", decision: "owner"),
        ]
        let provider = FakeServiceHealthProvider(healthy: true)
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: provider
        )
        await coordinator.refreshPermissions()
        await coordinator.runDiagnosis()
        await coordinator.verifyOwnerWithoutLocking()
        provider.healthy = false

        do {
            try await coordinator.enableProtection()
            throw TestFailure.assertion(
                "source protection enabled after its service provider became unhealthy"
            )
        } catch is SetupCoordinatorError {
            // Expected.
        }

        try require(provider.checks >= 2, "source enable did not live-refresh service health")
        try require(
            !fixture.localStore.readControl().protectionEnabled,
            "source service death still wrote protection enabled"
        )
    }

    private static func testRestoresSafeStepAndForwardsPermissionActions() async throws {
        let fixture = try CoordinatorFixture(mode: .source)
        defer { fixture.remove() }
        try fixture.setupStore.save(
            OnboardingRecord(
                currentStep: .enrollment,
                completedSteps: [.preparation, .permissions],
                completedAt: nil,
                appVersion: "test"
            )
        )
        let provider = CoordinatorPermissionProvider()
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: provider),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: FakeRuntimeRunner(),
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
        )

        try require(
            coordinator.currentStep == .enrollment,
            "coordinator did not restore the last persisted safe step"
        )
        try require(
            !coordinator.hasCompletedOnboarding,
            "incomplete record was reported as completed"
        )

        await coordinator.requestPermission(.camera)
        await coordinator.requestPermission(.inputMonitoring)
        await coordinator.requestPermission(.accessibility)
        await coordinator.requestPermission(.screenRecording)
        coordinator.openPermissionSettings(.inputMonitoring)

        try require(
            provider.requested == SetupPermission.allCases,
            "customer permission actions were not forwarded through PermissionCenter"
        )
        try require(
            provider.openedSettingsURLs.last?.absoluteString.contains("Privacy_ListenEvent")
                == true,
            "input monitoring settings action did not open the focused system page"
        )

        coordinator.goBack()
        try require(
            coordinator.currentStep == .permissions,
            "back navigation did not return to the prior setup step"
        )
        try require(
            fixture.setupStore.record.currentStep == .permissions,
            "back navigation was not persisted for safe resume"
        )
    }

    private static func testOperationalServiceRepairActionsUseServiceManager() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let serviceManager = FakeServiceManager(state: .healthy)
        let appURL = fixture.root.appendingPathComponent("Mac Face Lock.app")
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: FakeRuntimeRunner(),
            serviceManager: serviceManager,
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            applicationURL: appURL
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.restartService()
        await coordinator.reinstallService()

        try require(serviceManager.restartCount == 1, "service restart action was not forwarded")
        try require(serviceManager.installs.count == 1, "service reinstall action was not forwarded")
        try require(
            serviceManager.installs.first?.appURL == appURL,
            "service reinstall did not use the current application URL"
        )
        try require(
            coordinator.checks[.serviceHealth] == true,
            "service repair actions did not refresh live readiness"
        )
    }

    private static func testCompletedRecordDoesNotFabricateLiveRuntimeGates() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try Data("corrupted-template".utf8).write(
            to: fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        try fixture.setupStore.save(
            OnboardingRecord(
                currentStep: .completion,
                completedSteps: SetupStep.allCases,
                completedAt: "2026-07-17T12:00:00Z",
                appVersion: "test"
            )
        )
        let runner = FakeRuntimeRunner()
        runner.results[.diagnose] = RuntimeResult(
            exitCode: 11,
            events: [
                event("diagnosis_check", status: "error", check: "template"),
                RuntimeEvent(
                    schemaVersion: 1,
                    event: "diagnosis_complete",
                    status: "error",
                    message: "failed",
                    failedChecks: ["template"]
                ),
            ],
            stderr: "",
            stderrTruncated: false
        )
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceManager: FakeServiceManager(state: .healthy),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound)
        )

        try require(
            coordinator.checks[.diagnosis] == false
                && coordinator.checks[.ownerTest] == false,
            "completed record fabricated current diagnosis or owner-test success"
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.refreshLiveReadiness()

        try require(
            coordinator.checks[.ownerProfile] == false,
            "current diagnosis did not reject the corrupted owner profile"
        )
        try require(
            !coordinator.isLiveReady,
            "corrupted completed install was reported live ready"
        )
    }

    private static func testEnableProtectionReprobesRevokedPermissionAndFallsBack() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try Data("owner".utf8).write(
            to: fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        try fixture.setupStore.save(
            OnboardingRecord(
                currentStep: .completion,
                completedSteps: SetupStep.allCases,
                completedAt: "2026-07-17T12:00:00Z",
                appVersion: "test"
            )
        )
        _ = try fixture.localStore.writeControl(enabled: false)
        let provider = CoordinatorPermissionProvider()
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [
            event("diagnosis_check", check: "template"),
            event("diagnosis_complete"),
        ]
        runner.events[.verifyOwner] = [
            event("owner_verification_complete", decision: "owner"),
        ]
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: provider),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceManager: FakeServiceManager(state: .healthy),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound)
        )
        await coordinator.inspectLegacyInstall()
        await coordinator.refreshPermissions()
        provider.cameraStatus = .denied

        do {
            try await coordinator.enableProtection()
            throw TestFailure.assertion("protection enabled after accessibility was revoked")
        } catch is SetupCoordinatorError {
            // Expected.
        }

        try require(
            coordinator.permissionStates[.camera] == .denied,
            "final enable did not re-probe the revoked permission"
        )
        try require(
            coordinator.currentStep == .completion
                && coordinator.hasCompletedOnboarding
                && coordinator.recoveryStep == .permissions,
            "permission revocation did not preserve completion with permission recovery"
        )
        try require(
            fixture.setupStore.record.completedAt == "2026-07-17T12:00:00Z"
                && Set(fixture.setupStore.record.completedSteps)
                    == Set(SetupStep.allCases),
            "permission revocation discarded completed onboarding history"
        )
        try require(
            !fixture.localStore.readControl().protectionEnabled,
            "permission revocation did not keep protection disabled"
        )
    }

    private static func testCompletedInstallKeepsRecoverySurfaceWhenServiceIsUnhealthy()
        async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try Data("owner".utf8).write(
            to: fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        try fixture.setupStore.save(
            OnboardingRecord(
                currentStep: .completion,
                completedSteps: SetupStep.allCases,
                completedAt: "2026-07-17T12:00:00Z",
                appVersion: "test"
            )
        )
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [
            event("diagnosis_check", check: "template"),
            event("diagnosis_complete"),
        ]
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceManager: FakeServiceManager(state: .unhealthy),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound)
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.refreshLiveReadiness()

        try require(
            coordinator.hasCompletedOnboarding,
            "transient service failure erased completed onboarding"
        )
        try require(
            coordinator.currentStep == .completion,
            "transient service failure moved the user out of completed recovery"
        )
        try require(
            !coordinator.isLiveReady,
            "unhealthy service was reported live ready"
        )
    }

    private static func testCompletedAuthorizationRefreshFallsBackAfterRevocation()
        async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try fixture.setupStore.save(
            OnboardingRecord(
                currentStep: .completion,
                completedSteps: SetupStep.allCases,
                completedAt: "2026-07-17T12:00:00Z",
                appVersion: "test"
            )
        )
        let provider = CoordinatorPermissionProvider()
        provider.cameraStatus = .denied
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: provider),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: FakeRuntimeRunner(),
            serviceManager: FakeServiceManager(state: .healthy),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound)
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.refreshCurrentAuthorizationStatus()

        try require(
            coordinator.currentStep == .completion
                && coordinator.hasCompletedOnboarding
                && coordinator.recoveryStep == .permissions,
            "completion polling did not preserve completion with permission recovery"
        )
    }

    private static func testCancelImmediateRetryWaitsForRuntimeCleanup() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let runner = CancellationEOFWindowRunner()
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )
        let firstEnrollment = Task {
            await coordinator.startEnrollment()
        }
        for _ in 0..<40 where !runner.started {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        coordinator.cancelEnrollment()
        try require(
            coordinator.enrollmentLifecycle == .cancelling,
            "cancel did not publish the cancelling lifecycle"
        )
        await coordinator.startEnrollment()
        try require(
            runner.runCount == 1,
            "immediate retry launched before cancelled runtime reached EOF"
        )

        runner.deliverEOF()
        await firstEnrollment.value
        try require(
            coordinator.enrollmentLifecycle == .idle,
            "runtime cleanup did not return enrollment to idle"
        )

        await coordinator.startEnrollment()
        try require(
            runner.runCount == 2,
            "retry stayed blocked after cancelled runtime cleanup completed"
        )
    }

    private static func testServiceErrorsAreSanitizedBeforePublishing() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let serviceManager = FakeServiceManager(state: .unhealthy)
        let privatePath =
            "/" + "Users/private-customer/Library/LaunchAgents/secret-token"
        serviceManager.restartError = ServiceManagerError.commandFailed(
            command: "launchctl kickstart \(privatePath)",
            exitCode: 77,
            stderr: "API_SECRET=do-not-display"
        )
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: FakeRuntimeRunner(),
            serviceManager: serviceManager,
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound)
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.restartService()

        let customerError = coordinator.currentError ?? ""
        try require(!customerError.isEmpty, "service failure did not publish a repair message")
        for secret in ["launchctl", privatePath, "API_SECRET", "do-not-display", "77"] {
            try require(
                !customerError.contains(secret),
                "customer error leaked dynamic service detail: \(secret)"
            )
        }
    }

    private static func testOpenLogsReportsCustomerSafeFailure() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: FakeRuntimeRunner(),
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true),
            logOpener: { _ in false }
        )

        try require(!coordinator.openLogs(), "failed workspace open was reported as success")
        try require(
            coordinator.currentError == "无法打开日志文件夹，请稍后重试。",
            "log open failure did not publish a concise customer repair"
        )
    }

    private static func testHealthyCompletedRelaunchAndForegroundStayReadyWithoutRuntime()
        async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try Data("owner-placeholder".utf8).write(
            to: fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        try fixture.setupStore.save(
            OnboardingRecord(
                currentStep: .completion,
                completedSteps: SetupStep.allCases,
                completedAt: "2026-07-17T12:00:00Z",
                appVersion: "0.1.0-beta",
                ownerProfileFingerprint: "stable-owner",
                requiresOwnerReverification: false
            )
        )
        let runner = FakeRuntimeRunner()
        let inspector = FakeOwnerProfileInspector()
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceManager: FakeServiceManager(state: .healthy),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            ownerProfileInspector: inspector
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.refreshLiveReadiness()
        try require(coordinator.isLiveReady, "healthy completed relaunch was not ready")
        await coordinator.refreshLiveReadiness()

        try require(coordinator.isLiveReady, "foreground refresh cleared durable readiness")
        try require(
            runner.commands.isEmpty,
            "passive relaunch/foreground refresh launched a runtime camera command"
        )
        try require(
            coordinator.recoveryStep == nil,
            "healthy completed relaunch published a recovery step"
        )
    }

    private static func testFreshPreparationPassiveRefreshRunsNoRuntimeCommand()
        async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let runner = FakeRuntimeRunner()
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceManager: FakeServiceManager(state: .notInstalled),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            ownerProfileInspector: FakeOwnerProfileInspector(valid: false)
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.refreshLiveReadiness()
        await coordinator.refreshCurrentAuthorizationStatus()

        try require(
            coordinator.currentStep == .preparation,
            "passive first-run refresh advanced preparation"
        )
        try require(
            runner.commands.isEmpty,
            "passive first-run refresh launched diagnose before customer action"
        )
    }

    private static func testFreshReleaseContinuesThroughRequiredEnrollment()
        async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.environment.runtimeExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.environment.runtimeExecutableURL.path
        )
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: FakeRuntimeRunner(),
            serviceManager: FakeServiceManager(state: .notInstalled),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            applicationURL: URL(fileURLWithPath: "/Applications/Mac Face Lock.app"),
            ownerProfileInspector: FakeOwnerProfileInspector(valid: false)
        )

        let prepared = await coordinator.prepareForSetup()
        try require(prepared, "preparation did not continue without a migration choice")
        try require(
            coordinator.currentStep == .permissions,
            "preparation did not advance to permissions"
        )

        let continued = await coordinator.continueFromPermissions()
        try require(continued, "granted camera permission did not continue")
        try require(
            coordinator.currentStep == .enrollment,
            "release onboarding skipped required enrollment"
        )
    }

    private static func testFreshReleaseWithExistingOwnerStillRequiresEnrollment()
        async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.environment.runtimeExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.environment.runtimeExecutableURL.path
        )
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: FakeRuntimeRunner(),
            serviceManager: FakeServiceManager(state: .notInstalled),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            applicationURL: URL(fileURLWithPath: "/Applications/Mac Face Lock.app"),
            ownerProfileInspector: FakeOwnerProfileInspector(
                valid: true,
                fingerprint: "legacy-owner"
            )
        )

        let prepared = await coordinator.prepareForSetup()
        try require(prepared, "fresh release preparation did not continue")
        try require(
            coordinator.currentStep == .permissions,
            "fresh release preparation did not advance to permissions"
        )

        let continued = await coordinator.continueFromPermissions()
        try require(continued, "granted camera permission did not continue")
        try require(
            coordinator.currentStep == .enrollment,
            "existing owner template skipped required release enrollment"
        )
    }

    private static func testRuntimeDiagnosticsAreSerialized() async throws {
        let fixture = try CoordinatorFixture(mode: .source)
        defer { fixture.remove() }
        let runner = SerializedDiagnosisRunner()
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )

        let first = Task { await coordinator.runDiagnosis() }
        for _ in 0..<40 where runner.commands.count < 1 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let second = Task { await coordinator.runDiagnosis() }
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(
            runner.commands.count == 1,
            "second diagnosis entered runtime before first released the camera"
        )

        runner.completeNext()
        for _ in 0..<40 where runner.commands.count < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        runner.completeNext()
        await first.value
        await second.value

        try require(
            runner.maximumActiveCount == 1,
            "runtime readiness operations overlapped"
        )
    }

    private static func testStrictStaticOwnerProfileInspection() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let ownerURL = fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        let inspector = NumpyOwnerProfileInspector()

        try numpyOwnerProfileData().write(to: ownerURL)
        let valid = inspector.inspect(ownerURL)
        try require(
            valid.isValid && valid.fingerprint?.count == 64,
            "strict static inspection rejected a valid finite owner profile"
        )

        try numpyOwnerProfileData(firstValueIsNaN: true).write(to: ownerURL)
        try require(
            !inspector.inspect(ownerURL).isValid,
            "strict static inspection accepted non-finite template data"
        )

        try Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]).write(to: ownerURL)
        try require(
            !inspector.inspect(ownerURL).isValid,
            "strict static inspection accepted a truncated NPY file"
        )
    }

    private static func testAdversarialOwnerProfilesAreRejectedWithoutCoordinatorCrash()
        throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let ownerURL = fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        let validHeader =
            "{'descr': '<f4', 'fortran_order': False, 'shape': (2, 9216), }"
        let hostileFiles = [
            numpyContainer(
                header: "{'descr': '<f4', 'fortran_order': False, "
                    + "'shape': (9223372036854775807, 9216), }"
            ),
            numpyContainer(
                header: "{'descr': '<f4', 'descr': '<f4', "
                    + "'fortran_order': False, 'shape': (2, 9216), }",
                payloadBytes: 2 * 9_216 * 4
            ),
            numpyContainer(
                header: "{'descr': '|O', 'fortran_order': False, "
                    + "'shape': (2, 9216), 'note': '<f4', }",
                payloadBytes: 2 * 9_216 * 4
            ),
            numpyContainer(
                header: "{'descr': [('face', '<f4')], 'fortran_order': False, "
                    + "'shape': (2, 9216), }",
                payloadBytes: 2 * 9_216 * 4
            ),
            numpyContainer(
                header: "{'descr': '|O', 'fortran_order': False, "
                    + "'shape': (2, 9216), }",
                payloadBytes: 2 * 9_216 * 4
            ),
            numpyContainer(
                header: "{'descr': ('<f4', (2,)), 'fortran_order': False, "
                    + "'shape': (2, 9216), }",
                payloadBytes: 2 * 9_216 * 4
            ),
            numpyContainer(
                header: "{'descr': '>f4', 'fortran_order': False, "
                    + "'shape': (2, 9216), }",
                payloadBytes: 2 * 9_216 * 4
            ),
            numpyContainer(
                header: "{'descr': '<f4', 'fortran_order': True, "
                    + "'shape': (2, 9216), }",
                payloadBytes: 2 * 9_216 * 4
            ),
            numpyContainer(
                header: "{'descr': '<f4', 'fortran_order': False, "
                    + "'shape': (+2, 9216), }",
                payloadBytes: 2 * 9_216 * 4
            ),
            numpyContainer(
                header: "{'descr': '<f4', 'fortran_order': False, "
                    + "'shape': (2_0, 9216), }",
                payloadBytes: 20 * 9_216 * 4
            ),
            numpyContainer(
                header: validHeader,
                payloadBytes: 2 * 9_216 * 4 - 1
            ),
            numpyContainer(
                header: validHeader,
                payloadBytes: 0,
                declaredHeaderLength: validHeader.utf8.count + 128
            ),
            numpyContainer(
                header: "{'descr': '<f4', 'fortran_order': False, "
                    + "'shape': (999999999, 9216), }"
            ),
            numpyV2Container(declaredHeaderLength: UInt32.max),
        ]
        let inspector = NumpyOwnerProfileInspector()

        for (index, hostileFile) in hostileFiles.enumerated() {
            try hostileFile.write(to: ownerURL)
            try require(
                !inspector.inspect(ownerURL).isValid,
                "hostile NPY case \(index) was accepted"
            )
            _ = SetupCoordinator(
                environment: fixture.environment,
                permissionCenter: PermissionCenter(
                    provider: CoordinatorPermissionProvider()
                ),
                setupStore: fixture.setupStore,
                localStore: fixture.localStore,
                runtimeRunner: FakeRuntimeRunner(),
                serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
            )
        }
    }

    private static func testSharedNumpyHeaderCorpusMatchesSwiftInspector() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let corpusURL = URL(fileURLWithPath: "tests/fixtures/npy_header_corpus.json")
        let cases = try JSONDecoder().decode(
            [NumpyHeaderCorpusCase].self,
            from: Data(contentsOf: corpusURL)
        )
        let ownerURL = fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        let inspector = NumpyOwnerProfileInspector()

        for testCase in cases {
            try numpyCorpusData(testCase).write(to: ownerURL)
            try require(
                inspector.inspect(ownerURL).isValid == testCase.expected,
                "Swift disagreed with pinned NumPy corpus case: \(testCase.name)"
            )
        }
    }

    private static func numpyCorpusData(_ testCase: NumpyHeaderCorpusCase) -> Data {
        var header = Data(testCase.header.utf8)
        let padding = testCase.headerLength - header.count - 1
        header.append(Data(repeating: 0x20, count: padding))
        header.append(0x0A)
        var data = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59])
        if testCase.version == 1 {
            data.append(contentsOf: [0x01, 0x00])
            let length = UInt16(header.count)
            data.append(UInt8(length & 0x00FF))
            data.append(UInt8((length >> 8) & 0x00FF))
        } else {
            data.append(contentsOf: [0x02, 0x00])
            let length = UInt32(header.count)
            data.append(UInt8(length & 0x000000FF))
            data.append(UInt8((length >> 8) & 0x000000FF))
            data.append(UInt8((length >> 16) & 0x000000FF))
            data.append(UInt8((length >> 24) & 0x000000FF))
        }
        data.append(header)
        data.append(
            Data(repeating: 0, count: testCase.payloadRows * 9_216 * 4)
        )
        return data
    }

    private static func numpyContainer(
        header: String,
        payloadBytes: Int = 0,
        declaredHeaderLength: Int? = nil
    ) -> Data {
        let headerBytes = Data(header.utf8)
        let declared = UInt16(declaredHeaderLength ?? headerBytes.count)
        var data = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 0x01, 0x00])
        data.append(UInt8(declared & 0x00FF))
        data.append(UInt8((declared >> 8) & 0x00FF))
        data.append(headerBytes)
        data.append(Data(repeating: 0, count: payloadBytes))
        return data
    }

    private static func numpyV2Container(declaredHeaderLength: UInt32) -> Data {
        var data = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 0x02, 0x00])
        data.append(UInt8(declaredHeaderLength & 0x000000FF))
        data.append(UInt8((declaredHeaderLength >> 8) & 0x000000FF))
        data.append(UInt8((declaredHeaderLength >> 16) & 0x000000FF))
        data.append(UInt8((declaredHeaderLength >> 24) & 0x000000FF))
        return data
    }

    private static func numpyOwnerProfileData(firstValueIsNaN: Bool = false) -> Data {
        var header = "{'descr': '<f4', 'fortran_order': False, 'shape': (2, 9216), }"
        let padding = (16 - ((10 + header.utf8.count + 1) % 16)) % 16
        header += String(repeating: " ", count: padding) + "\n"
        let headerBytes = Data(header.utf8)
        let headerLength = UInt16(headerBytes.count)
        var data = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 0x01, 0x00])
        data.append(UInt8(headerLength & 0x00FF))
        data.append(UInt8((headerLength >> 8) & 0x00FF))
        data.append(headerBytes)
        var payload = Data(repeating: 0, count: 2 * 9_216 * 4)
        if firstValueIsNaN {
            payload[0] = 0x00
            payload[1] = 0x00
            payload[2] = 0xC0
            payload[3] = 0x7F
        }
        data.append(payload)
        return data
    }

    private static func testQueuedEnrollmentCancellationNeverStartsRuntime() async throws {
        let fixture = try CoordinatorFixture(mode: .source)
        defer { fixture.remove() }
        let runner = EnrollmentQueueCancellationRunner()
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )
        let blocker = Task {
            await coordinator.runDiagnosis()
        }
        for _ in 0..<40 where !runner.diagnosisStarted {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try require(runner.diagnosisStarted, "diagnosis did not hold the runtime permit")

        var cancelledEnrollmentFinished = false
        let cancelledEnrollment = Task {
            await coordinator.startEnrollment()
            cancelledEnrollmentFinished = true
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancelledEnrollment.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        let finishedBeforePermitRelease = cancelledEnrollmentFinished

        runner.completeDiagnosis()
        await blocker.value
        await cancelledEnrollment.value

        try require(
            finishedBeforePermitRelease,
            "cancelled queued enrollment stayed suspended until permit release"
        )
        try require(
            runner.enrollmentCommands == 0,
            "cancelled queued enrollment started the camera runtime"
        )

        await coordinator.startEnrollment()
        try require(
            runner.enrollmentCommands == 1,
            "permit queue leaked or normal enrollment could not retry after cancellation"
        )
    }

    private static func testParentCancellationPropagatesToEnrollmentChildAtStart()
        async throws {
        let fixture = try CoordinatorFixture(mode: .source)
        defer { fixture.remove() }
        let runner = EnrollmentChildStartWindowRunner()
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )
        let cancelledEnrollment = Task {
            await coordinator.startEnrollment()
        }
        for _ in 0..<80 where !runner.firstEnrollmentEntered {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try require(
            runner.firstEnrollmentEntered,
            "enrollment child did not enter the pre-camera start window"
        )

        cancelledEnrollment.cancel()
        runner.releaseFirstEnrollmentStartWindow()
        await cancelledEnrollment.value

        try require(
            runner.cameraStarts == 0,
            "parent cancellation did not stop the enrollment child before camera start"
        )

        await coordinator.startEnrollment()
        try require(
            runner.enrollmentEntries == 2 && runner.cameraStarts == 1,
            "normal enrollment deadlocked after parent cancellation"
        )
    }

    private static func testCameraOnlyDiagnosisKeepsValidOwnerProfile() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let runner = FakeRuntimeRunner()
        runner.results[.diagnose] = RuntimeResult(
            exitCode: 10,
            events: [
                event("diagnosis_check", check: "template"),
                event("diagnosis_check", status: "error", check: "camera"),
                RuntimeEvent(
                    schemaVersion: 1,
                    event: "diagnosis_complete",
                    status: "error",
                    message: "camera only",
                    failedChecks: ["camera"]
                ),
            ],
            stderr: "",
            stderrTruncated: false
        )
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceManager: FakeServiceManager(state: .healthy),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.runDiagnosis()

        try require(
            coordinator.checks[.ownerProfile] == true,
            "camera-only diagnosis failure invalidated a successful template check"
        )
        try require(
            coordinator.checks[.diagnosis] == false,
            "camera-only diagnosis failure was reported as full diagnosis success"
        )
        try require(
            coordinator.currentError?.contains("摄像头") == true,
            "camera-only diagnosis did not publish the camera repair"
        )
    }

    private static func testCompletedCameraRevocationRecoveryPreservesHistoryAndSkipsEnrollment()
        async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let completedAt = "2026-07-17T12:00:00Z"
        try fixture.setupStore.save(
            OnboardingRecord(
                currentStep: .completion,
                completedSteps: SetupStep.allCases,
                completedAt: completedAt,
                appVersion: "0.1.0-beta",
                ownerProfileFingerprint: "stable-owner",
                requiresOwnerReverification: false
            )
        )
        let provider = CoordinatorPermissionProvider()
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: provider),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: FakeRuntimeRunner(),
            serviceManager: FakeServiceManager(state: .healthy),
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )
        await coordinator.inspectLegacyInstall()
        await coordinator.refreshLiveReadiness()
        provider.cameraStatus = .denied

        await coordinator.refreshCurrentAuthorizationStatus()

        try require(
            coordinator.hasCompletedOnboarding,
            "camera revocation destroyed historical onboarding completion"
        )
        try require(
            fixture.setupStore.record.completedAt == completedAt
                && Set(fixture.setupStore.record.completedSteps)
                    == Set(SetupStep.allCases),
            "camera revocation discarded completed steps or timestamp"
        )
        try require(
            coordinator.recoveryStep == .permissions,
            "camera revocation did not identify the permission recovery step"
        )

        provider.cameraStatus = .authorized
        await coordinator.refreshCurrentAuthorizationStatus()

        try require(
            coordinator.hasCompletedOnboarding
                && coordinator.currentStep == .completion,
            "restored camera permission forced the completed install into onboarding"
        )
        try require(
            coordinator.recoveryStep == .safetyTest,
            "restored camera did not advance recovery to owner re-verification"
        )
        try require(
            coordinator.recoveryStep != .enrollment
                && coordinator.checks[.ownerProfile] == true,
            "restored camera unnecessarily requested owner enrollment"
        )
    }

    private static func testUnsafePersistedStepFallsBackToLastSatisfiedGate() throws {
        let fixture = try CoordinatorFixture(mode: .source)
        defer { fixture.remove() }
        try fixture.setupStore.save(
            OnboardingRecord(
                currentStep: .completion,
                completedSteps: [.preparation, .permissions],
                completedAt: nil,
                appVersion: "test"
            )
        )

        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: FakeRuntimeRunner(),
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
        )

        try require(
            coordinator.currentStep == .enrollment,
            "an unsafe persisted step skipped the missing enrollment gate"
        )
        try require(
            fixture.setupStore.record.currentStep == .enrollment,
            "safe fallback step was not persisted for the next relaunch"
        )
    }

    private static func testFailedReenrollmentPreservesExistingOwnerProfile() async throws {
        let fixture = try CoordinatorFixture(mode: .source)
        defer { fixture.remove() }
        try Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]).write(
            to: fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        let runner = FakeRuntimeRunner()
        runner.results[.enroll] = RuntimeResult(
            exitCode: 10,
            events: [
                event("camera_unavailable", status: "error"),
            ],
            stderr: "",
            stderrTruncated: false
        )
        runner.events[.diagnose] = [event("diagnosis_complete")]
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.runDiagnosis()
        await coordinator.startEnrollment()

        try require(
            coordinator.checks[.ownerProfile] == true,
            "failed re-enrollment discarded the still-valid existing owner profile"
        )
    }

    private static func testSuccessfulEnrollmentRequiresSuccessfulTerminalStatus() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]).write(
            to: fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        let runner = FakeRuntimeRunner()
        runner.results[.enroll] = RuntimeResult(
            exitCode: 0,
            events: [
                event("enrollment_complete", status: "error"),
            ],
            stderr: "",
            stderrTruncated: false
        )
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
        )

        await coordinator.startEnrollment()

        try require(
            !fixture.setupStore.record.completedSteps.contains(.enrollment),
            "coordinator persisted enrollment without a successful terminal event"
        )
        try require(
            coordinator.currentError != nil,
            "contradictory enrollment terminal did not publish an error"
        )
    }

    private static func testVerificationCannotPassAfterEnrollmentReplacesProfile() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let profileURL = fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        try Data("original-template".utf8).write(to: profileURL)
        let runner = VerificationEnrollmentOverlapRunner(replacementURL: profileURL)
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )
        let verification = Task {
            await coordinator.verifyOwnerWithoutLocking()
        }
        for _ in 0..<40 where !runner.verificationStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(runner.verificationStarted, "owner verification did not start")

        let enrollment = Task {
            await coordinator.startEnrollment()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(
            !runner.enrollmentStarted,
            "enrollment overlapped the active owner-verification camera operation"
        )
        runner.completeVerification()
        await verification.value
        await enrollment.value

        try require(
            coordinator.checks[.ownerTest] == false,
            "verification for the replaced profile incorrectly passed owner readiness"
        )
    }

    private static func testVerificationDoesNotLaunchDuringActiveEnrollment() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let profileURL = fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        try Data("original-template".utf8).write(to: profileURL)
        let runner = EnrollmentVerificationSerializationRunner(replacementURL: profileURL)
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
        )
        let enrollment = Task {
            await coordinator.startEnrollment()
        }
        for _ in 0..<40 where !runner.enrollmentStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(runner.enrollmentStarted, "enrollment-first overlap did not start")

        await coordinator.verifyOwnerWithoutLocking()

        try require(
            !runner.commands.contains(.verifyOwner),
            "verify-owner runtime command launched while enrollment was active"
        )
        try require(
            coordinator.checks[.ownerTest] == false,
            "owner test passed while enrollment was active"
        )
        try require(
            coordinator.checks[.ownerProfile] == false,
            "mere file existence fabricated a validated owner profile"
        )
        try require(
            coordinator.currentError?.contains("录入") == true
                && (coordinator.currentError?.count ?? 0) < 50,
            "active-enrollment refusal did not publish a concise repair message"
        )

        runner.completeEnrollment()
        await enrollment.value
    }

    private static func testSuccessfulEnrollmentClearsActiveEnrollmentRefusal() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let ownerURL = fixture.environment.dataURL.appendingPathComponent("owner_face.npy")
        let runner = EnrollmentVerificationSerializationRunner(replacementURL: ownerURL)
        let permissionCenter = PermissionCenter(provider: CoordinatorPermissionProvider())
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: permissionCenter,
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true),
            ownerProfileInspector: FakeOwnerProfileInspector()
        )

        let enrollment = Task {
            await coordinator.startEnrollment()
        }
        for _ in 0..<40 where !runner.enrollmentStarted {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await coordinator.verifyOwnerWithoutLocking()
        try require(
            coordinator.currentError?.contains("录入正在进行") == true,
            "active enrollment refusal was not published"
        )

        runner.completeEnrollment()
        await enrollment.value

        try require(
            coordinator.currentError == nil,
            "successful enrollment retained the transient active-enrollment refusal"
        )
    }

    private static func testReleaseDiagnosisInstallsAndUsesAgentOwnedServiceHealth() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [event("diagnosis_complete")]
        let serviceManager = FakeServiceManager(state: .healthy)
        let applicationURL = fixture.root.appendingPathComponent("Mac Face Lock.app")
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceManager: serviceManager,
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound),
            applicationURL: applicationURL
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.runDiagnosis()

        try require(
            serviceManager.installs.count == 1,
            "release diagnosis did not install and verify the background service"
        )
        try require(
            serviceManager.installs.first?.appURL == applicationURL
                && serviceManager.installs.first?.supportURL == fixture.environment.supportURL,
            "release service install received the wrong application or support path"
        )
        try require(
            coordinator.checks[.serviceHealth] == true,
            "healthy Agent-owned service state did not satisfy service readiness"
        )
    }

    private static func testVisibleAppGrantsCannotOverrideUnhealthyAgentPermissions() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [event("diagnosis_complete")]
        let serviceManager = FakeServiceManager(state: .unhealthy)
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceManager: serviceManager,
            legacyInstallCleaner: FakeLegacyInstallCleaner(inspection: .notFound)
        )

        await coordinator.inspectLegacyInstall()
        await coordinator.refreshPermissions()
        await coordinator.runDiagnosis()

        try require(
            coordinator.permissionStates[.camera] == .granted
                && coordinator.permissionStates[.inputMonitoring] == .granted
                && coordinator.permissionStates[.accessibility] == .granted,
            "fixture did not establish visible-app grants"
        )
        try require(
            coordinator.checks[.serviceHealth] == false,
            "visible-app grants overrode unhealthy Agent permission state"
        )
        try require(
            coordinator.checks[.inputMonitoringPermission] == false
                && coordinator.checks[.accessibilityPermission] == false,
            "visible-app grants were mislabeled as Agent input/accessibility grants"
        )
        try require(
            !coordinator.readiness.canEnableProtection,
            "protection became available while Agent permission health was false"
        )
    }

    private static func testSourceModePreservesExistingServiceHealthBoundary() async throws {
        let fixture = try CoordinatorFixture(mode: .source)
        defer { fixture.remove() }
        let runner = FakeRuntimeRunner()
        runner.events[.diagnose] = [event("diagnosis_complete")]
        let serviceManager = FakeServiceManager(state: .healthy)
        let provider = FakeServiceHealthProvider(healthy: true)
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceManager: serviceManager,
            serviceHealthProvider: provider
        )

        await coordinator.runDiagnosis()

        try require(
            serviceManager.installs.isEmpty,
            "source mode attempted to install the release LaunchAgent"
        )
        try require(
            coordinator.checks[.serviceHealth] == true,
            "source mode stopped honoring its existing health boundary"
        )
    }

    private static func testCancellationIgnoresLateProgress() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let runner = LateEventCancellationRunner()
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
        )
        let enrollment = Task {
            await coordinator.startEnrollment()
        }
        for _ in 0..<40 where !runner.started {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(runner.started, "cancellable enrollment did not start")

        coordinator.cancelEnrollment()
        await enrollment.value
        try await Task.sleep(nanoseconds: 100_000_000)

        try require(
            coordinator.progress == nil,
            "late progress restored state after enrollment cancellation"
        )
    }

    private static func testCancellationInvalidatesCallbacksBeforeRuntimeEOF() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let runner = CancellationEOFWindowRunner()
        let coordinator = SetupCoordinator(
            environment: fixture.environment,
            permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
            setupStore: fixture.setupStore,
            localStore: fixture.localStore,
            runtimeRunner: runner,
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
        )
        let enrollment = Task {
            await coordinator.startEnrollment()
        }
        for _ in 0..<40 where !runner.started {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(runner.started, "EOF-window enrollment did not start")

        coordinator.cancelEnrollment()
        try require(
            coordinator.progress == nil,
            "cancelEnrollment did not synchronously clear visible progress"
        )
        await Task.yield()
        await Task.yield()
        try require(
            coordinator.progress == nil,
            "callback during the TERM/EOF window restored cancelled progress"
        )

        runner.deliverEOF()
        await enrollment.value
    }
}
