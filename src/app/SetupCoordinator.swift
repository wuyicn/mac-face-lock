import Combine
import Foundation

enum SetupCoordinatorError: Error, Equatable, LocalizedError {
    case notReady([SetupCheck])
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "必要设置尚未完成，请先修复未通过的检查。"
        case .persistenceFailed:
            return "无法保存保护设置，请检查应用支持目录权限后重试。"
        }
    }
}

protocol SetupServiceHealthProviding: AnyObject {
    func isServiceHealthy() async -> Bool
}

private final class UnavailableSetupServiceHealthProvider: SetupServiceHealthProviding {
    func isServiceHealthy() async -> Bool {
        false
    }
}

@MainActor
final class SetupCoordinator: ObservableObject {
    @Published private(set) var progress: Double?
    @Published private(set) var currentError: String?
    @Published private(set) var permissionStates: [SetupPermission: PermissionState]
    @Published private(set) var checks: [SetupCheck: Bool]
    @Published private(set) var readiness: SetupReadiness

    private let environment: AppEnvironment
    private let permissionCenter: PermissionCenter
    private let setupStore: SetupStore
    private let localStore: LocalJSONStore
    private let runtimeRunner: RuntimeCommandRunning
    private let serviceHealthProvider: SetupServiceHealthProviding
    private let fileManager: FileManager

    private var ownerProfileValid: Bool
    private var diagnosisPassed = false
    private var ownerTestPassed = false
    private var serviceHealthy = false
    private var enrollmentTask: Task<RuntimeResult, Error>?
    private var enrollmentGeneration: UUID?
    private var profileRevision: UInt64 = 0

    init(
        environment: AppEnvironment,
        permissionCenter: PermissionCenter,
        setupStore: SetupStore,
        localStore: LocalJSONStore,
        runtimeRunner: RuntimeCommandRunning? = nil,
        serviceHealthProvider: SetupServiceHealthProviding? = nil,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.permissionCenter = permissionCenter
        self.setupStore = setupStore
        self.localStore = localStore
        self.runtimeRunner = runtimeRunner ?? RuntimeCommandRunner(environment: environment)
        self.serviceHealthProvider =
            serviceHealthProvider ?? UnavailableSetupServiceHealthProvider()
        self.fileManager = fileManager
        self.progress = nil
        self.currentError = nil
        self.permissionStates = [:]
        self.ownerProfileValid = fileManager.fileExists(
            atPath: environment.dataURL.appendingPathComponent("owner_face.npy").path
        )
        let initialReadiness = SetupReadiness.evaluate(
            permissions: [:],
            ownerProfileValid: self.ownerProfileValid,
            diagnosisPassed: false,
            ownerTestPassed: false,
            serviceHealthy: false
        )
        self.readiness = initialReadiness
        self.checks = initialReadiness.checks
    }

    func refreshPermissions() async {
        permissionStates = await permissionCenter.refresh()
        updateReadiness()
    }

    func startEnrollment() async {
        guard enrollmentTask == nil else {
            return
        }
        profileRevision &+= 1
        currentError = nil
        progress = 0
        ownerTestPassed = false
        updateReadiness()
        let generation = UUID()
        enrollmentGeneration = generation

        let task = Task { [runtimeRunner] in
            try await runtimeRunner.run(command: .enroll) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.applyEnrollment(event, generation: generation)
                }
            }
        }
        enrollmentTask = task
        defer {
            enrollmentTask = nil
            if enrollmentGeneration == generation {
                enrollmentGeneration = nil
            }
        }

        do {
            let result = try await task.value
            applyEnrollment(result.events, generation: generation)
            guard handleExitCode(result.exitCode) else {
                ownerProfileValid = fileManager.fileExists(
                    atPath: environment.dataURL.appendingPathComponent("owner_face.npy").path
                )
                updateReadiness()
                return
            }
            guard result.events.contains(where: {
                $0.event == "enrollment_complete" && $0.status == "success"
            }) else {
                currentError = "录入未返回有效的完成结果，请重新运行诊断后再试。"
                updateReadiness()
                return
            }
            ownerProfileValid = fileManager.fileExists(
                atPath: environment.dataURL.appendingPathComponent("owner_face.npy").path
            )
            guard ownerProfileValid else {
                currentError = "录入结束但未找到本人人脸资料，请重新录入。"
                updateReadiness()
                return
            }
            try markEnrollmentCompleted()
            updateReadiness()
        } catch is CancellationError {
            enrollmentGeneration = nil
            currentError = nil
            progress = nil
        } catch {
            currentError = localizedRuntimeError(error)
        }
    }

    func cancelEnrollment() {
        enrollmentGeneration = nil
        progress = nil
        let task = enrollmentTask
        task?.cancel()
    }

    func runDiagnosis() async {
        currentError = nil
        diagnosisPassed = false
        do {
            let result = try await runtimeRunner.run(command: .diagnose) { _ in }
            diagnosisPassed = result.exitCode == 0
                && result.events.contains {
                    $0.event == "diagnosis_complete" && $0.status == "success"
                }
            if !handleExitCode(result.exitCode) {
                diagnosisPassed = false
            }
        } catch {
            currentError = localizedRuntimeError(error)
            diagnosisPassed = false
        }
        serviceHealthy = await serviceHealthProvider.isServiceHealthy()
        updateReadiness()
    }

    func verifyOwnerWithoutLocking() async {
        currentError = nil
        ownerTestPassed = false
        let verificationRevision = profileRevision
        do {
            let result = try await runtimeRunner.run(command: .verifyOwner) { _ in }
            guard verificationRevision == profileRevision else {
                updateReadiness()
                return
            }
            ownerTestPassed = result.exitCode == 0
                && result.events.contains {
                    $0.event == "owner_verification_complete"
                        && $0.status == "success"
                        && $0.decision == "owner"
                }
            if !handleExitCode(result.exitCode) {
                ownerTestPassed = false
            }
        } catch {
            guard verificationRevision == profileRevision else {
                updateReadiness()
                return
            }
            currentError = localizedRuntimeError(error)
            ownerTestPassed = false
        }
        updateReadiness()
    }

    func enableProtection() throws {
        updateReadiness()
        let missingChecks = readiness.requiredChecks
            .filter { readiness.checks[$0] != true }
            .sorted { $0.rawValue < $1.rawValue }
        guard missingChecks.isEmpty else {
            let error = SetupCoordinatorError.notReady(missingChecks)
            currentError = error.localizedDescription
            throw error
        }

        let previousRecord = setupStore.record
        let completedRecord = OnboardingRecord(
            currentStep: .completion,
            completedSteps: SetupStep.allCases,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion
        )
        do {
            try setupStore.save(completedRecord)
            _ = try localStore.writeControl(enabled: true)
            currentError = nil
        } catch {
            try? setupStore.save(previousRecord)
            let coordinatorError = SetupCoordinatorError.persistenceFailed
            currentError = coordinatorError.localizedDescription
            throw coordinatorError
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return version?.isEmpty == false ? version! : "0.1.0-beta"
    }

    private func markEnrollmentCompleted() throws {
        var completedSteps = setupStore.record.completedSteps
        if !completedSteps.contains(.enrollment) {
            completedSteps.append(.enrollment)
        }
        let record = OnboardingRecord(
            currentStep: .safetyTest,
            completedSteps: completedSteps,
            completedAt: nil,
            appVersion: appVersion
        )
        try setupStore.save(record)
    }

    private func applyEnrollment(
        _ events: [RuntimeEvent],
        generation: UUID
    ) {
        for event in events {
            applyEnrollment(event, generation: generation)
        }
    }

    private func applyEnrollment(
        _ event: RuntimeEvent,
        generation: UUID
    ) {
        guard enrollmentGeneration == generation else {
            return
        }
        if event.event == "enrollment_complete", event.status == "success" {
            progress = 1
            return
        }
        guard event.event == "enrollment_progress",
              let captured = event.capturedSamples,
              let required = event.requiredSamples,
              required > 0 else {
            return
        }
        progress = min(max(Double(captured) / Double(required), 0), 1)
    }

    @discardableResult
    private func handleExitCode(_ exitCode: Int32) -> Bool {
        guard exitCode != 0 else {
            return true
        }
        currentError = Self.repairInstruction(for: exitCode)
        return false
    }

    private func localizedRuntimeError(_ error: Error) -> String {
        if let error = error as? LocalizedError,
           let description = error.errorDescription {
            return description
        }
        return "运行组件未能完成，请重新运行诊断。"
    }

    private func updateReadiness() {
        let evaluated = SetupReadiness.evaluate(
            permissions: permissionStates,
            ownerProfileValid: ownerProfileValid,
            diagnosisPassed: diagnosisPassed,
            ownerTestPassed: ownerTestPassed,
            serviceHealthy: serviceHealthy
        )
        readiness = evaluated
        checks = evaluated.checks
    }

    private static func repairInstruction(for exitCode: Int32) -> String {
        switch exitCode {
        case 2:
            return "运行参数无效，请重新安装应用后再试。"
        case 10:
            return "摄像头或权限不可用，请完成系统授权并关闭占用摄像头的应用。"
        case 11:
            return "本人人脸资料无效，请重新录入本人。"
        case 12:
            return "未能确认当前使用者是本人，请调整光线和姿势后重试。"
        case 20:
            return "运行组件发生错误，请重新运行诊断；若仍失败，请重新安装应用。"
        default:
            return "运行组件异常退出（代码 \(exitCode)），请重新运行诊断。"
        }
    }
}
