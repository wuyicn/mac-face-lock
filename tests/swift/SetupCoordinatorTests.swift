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
        for event in events[command, default: []] {
            onEvent(event)
        }
        return results[command] ?? RuntimeResult(
            exitCode: 0,
            events: events[command, default: []],
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

private final class FakeServiceManager: ServiceManaging {
    var currentStatus: ServiceStatus
    var installError: Error?
    var restartError: Error?
    private(set) var installs: [(appURL: URL, supportURL: URL)] = []
    private(set) var restartCount = 0
    private(set) var uninstallCount = 0

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
    }

    func status() async -> ServiceStatus {
        currentStatus
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
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
        )

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
                serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
            )

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
            serviceHealthProvider: FakeServiceHealthProvider(healthy: false)
        )
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
            serviceManager: serviceManager
        )
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
            applicationURL: appURL
        )

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
            serviceManager: FakeServiceManager(state: .healthy)
        )

        try require(
            coordinator.checks[.diagnosis] == false
                && coordinator.checks[.ownerTest] == false,
            "completed record fabricated current diagnosis or owner-test success"
        )

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
            serviceManager: FakeServiceManager(state: .healthy)
        )
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
            coordinator.currentStep == .permissions
                && !coordinator.hasCompletedOnboarding,
            "permission revocation did not fall back to the permission step"
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
            serviceManager: FakeServiceManager(state: .unhealthy)
        )

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
            serviceManager: FakeServiceManager(state: .healthy)
        )

        await coordinator.refreshCurrentAuthorizationStatus()

        try require(
            coordinator.currentStep == .permissions
                && !coordinator.hasCompletedOnboarding,
            "completion polling did not fall back after a required permission was revoked"
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
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
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
        let privatePath = "/Users/private-customer/Library/LaunchAgents/secret-token"
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
            serviceManager: serviceManager
        )

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
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
        )

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
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
        )
        let verification = Task {
            await coordinator.verifyOwnerWithoutLocking()
        }
        for _ in 0..<40 where !runner.verificationStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(runner.verificationStarted, "owner verification did not start")

        await coordinator.startEnrollment()
        runner.completeVerification()
        await verification.value

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
            serviceHealthProvider: FakeServiceHealthProvider(healthy: true)
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
            applicationURL: applicationURL
        )

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
            serviceManager: serviceManager
        )

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
