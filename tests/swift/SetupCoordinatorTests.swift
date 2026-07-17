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

    func cameraAuthorizationStatus() -> AVAuthorizationStatus {
        cameraStatus
    }

    func isGranted(_ permission: SetupPermission) -> Bool {
        granted.contains(permission)
    }

    func requiresApplicationRestart(for permission: SetupPermission) -> Bool {
        false
    }

    func requestCameraAccess() async {}
    func requestInputMonitoringAccess() {}
    func requestAccessibilityAccess() {}
    func requestScreenRecordingAccess() {}

    func open(_ url: URL) -> Bool {
        true
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

    init(healthy: Bool) {
        self.healthy = healthy
    }

    func isServiceHealthy() async -> Bool {
        healthy
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

private struct CoordinatorFixture {
    let root: URL
    let localStore: LocalJSONStore
    let setupStore: SetupStore
    let environment: AppEnvironment

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-face-lock-coordinator-\(UUID().uuidString)")
        let dataURL = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        localStore = LocalJSONStore(resourcesURL: root, dataURL: dataURL)
        setupStore = try SetupStore(localStore: localStore, mode: .release)
        environment = AppEnvironment(
            mode: .release,
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
        try await testEnableProtectionRefusesWhenAnyGateIsFalse()
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
            try coordinator.enableProtection()
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

    private static func testFailedReenrollmentPreservesExistingOwnerProfile() async throws {
        let fixture = try CoordinatorFixture()
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
}
