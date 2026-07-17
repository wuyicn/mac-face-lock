import AppKit
import Combine
import CryptoKit
import Foundation

struct OwnerProfileInspection: Equatable {
    let isValid: Bool
    let fingerprint: String?
}

protocol OwnerProfileInspecting: AnyObject {
    func inspect(_ url: URL) -> OwnerProfileInspection
}

final class NumpyOwnerProfileInspector: OwnerProfileInspecting {
    private let maximumBytes = 64 * 1_024 * 1_024
    private let expectedColumns = 96 * 96

    func inspect(_ url: URL) -> OwnerProfileInspection {
        guard let data = try? Data(
            contentsOf: url,
            options: [.mappedIfSafe]
        ), data.count >= 16, data.count <= maximumBytes,
              Array(data.prefix(6)) == [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59] else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let major = data[6]
        let headerStart: Int
        let headerLength: Int
        if major == 1, data.count >= 10 {
            headerStart = 10
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
        } else if (major == 2 || major == 3), data.count >= 12 {
            headerStart = 12
            headerLength = Int(data[8])
                | (Int(data[9]) << 8)
                | (Int(data[10]) << 16)
                | (Int(data[11]) << 24)
        } else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let payloadStart = headerStart + headerLength
        guard headerLength > 0, payloadStart <= data.count,
              let header = String(
                  data: data[headerStart..<payloadStart],
                  encoding: .ascii
              ),
              header.contains("'fortran_order': False")
                || header.contains("\"fortran_order\": False"),
              header.contains("'<f4'")
                || header.contains("\"<f4\"")
                || header.contains("'=f4'")
                || header.contains("\"=f4\""),
              let shape = parseShape(header),
              shape.rows >= 2,
              shape.columns == expectedColumns else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let valueCount = shape.rows.multipliedReportingOverflow(by: shape.columns)
        guard !valueCount.overflow else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let payloadBytes = valueCount.partialValue.multipliedReportingOverflow(by: 4)
        guard !payloadBytes.overflow,
              payloadStart + payloadBytes.partialValue == data.count else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        var offset = payloadStart
        while offset < data.count {
            let bits = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            guard Float(bitPattern: bits).isFinite else {
                return OwnerProfileInspection(isValid: false, fingerprint: nil)
            }
            offset += 4
        }
        let fingerprint = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return OwnerProfileInspection(isValid: true, fingerprint: fingerprint)
    }

    private func parseShape(_ header: String) -> (rows: Int, columns: Int)? {
        let pattern = #"'shape'\s*:\s*\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,?\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: header,
                  range: NSRange(header.startIndex..., in: header)
              ),
              let rowsRange = Range(match.range(at: 1), in: header),
              let columnsRange = Range(match.range(at: 2), in: header),
              let rows = Int(header[rowsRange]),
              let columns = Int(header[columnsRange]) else {
            return nil
        }
        return (rows, columns)
    }
}

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
    @Published private(set) var currentStep: SetupStep
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var serviceStatus: ServiceStatus?
    @Published private(set) var enrollmentLifecycle: EnrollmentLifecycle
    @Published private(set) var recoveryStep: SetupStep?

    private let environment: AppEnvironment
    private let permissionCenter: PermissionCenter
    private let setupStore: SetupStore
    private let localStore: LocalJSONStore
    private let runtimeRunner: RuntimeCommandRunning
    private let serviceManager: ServiceManaging?
    private let serviceHealthProvider: SetupServiceHealthProviding
    private let applicationURL: URL
    private let fileManager: FileManager
    private let logOpener: (URL) -> Bool
    private let ownerProfileInspector: OwnerProfileInspecting

    private var ownerProfileValid: Bool
    private var diagnosisPassed: Bool
    private var ownerTestPassed: Bool
    private var serviceHealthy = false
    private var enrollmentTask: Task<RuntimeResult, Error>?
    private var enrollmentGeneration: UUID?
    private var profileRevision: UInt64 = 0
    private var currentOwnerFingerprint: String?
    private var runtimeValidationRequired: Bool
    private var runtimeReadinessBusy = false
    private var runtimeReadinessWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        environment: AppEnvironment,
        permissionCenter: PermissionCenter,
        setupStore: SetupStore,
        localStore: LocalJSONStore,
        runtimeRunner: RuntimeCommandRunning? = nil,
        serviceManager: ServiceManaging? = nil,
        serviceHealthProvider: SetupServiceHealthProviding? = nil,
        applicationURL: URL? = nil,
        fileManager: FileManager = .default,
        logOpener: ((URL) -> Bool)? = nil,
        ownerProfileInspector: OwnerProfileInspecting? = nil
    ) {
        let storedRecord = setupStore.record
        let resolvedOwnerProfileInspector =
            ownerProfileInspector ?? NumpyOwnerProfileInspector()
        let initialInspection = resolvedOwnerProfileInspector.inspect(
            environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        let restoredStep = Self.safeRestoredStep(
            for: storedRecord,
            ownerProfileValid: initialInspection.isValid
        )
        let durableOwnerEvidence = storedRecord.isComplete
            && storedRecord.requiresOwnerReverification != true
            && initialInspection.isValid
            && storedRecord.ownerProfileFingerprint != nil
            && storedRecord.ownerProfileFingerprint == initialInspection.fingerprint
        self.environment = environment
        self.permissionCenter = permissionCenter
        self.setupStore = setupStore
        self.localStore = localStore
        self.runtimeRunner = runtimeRunner ?? RuntimeCommandRunner(environment: environment)
        let resolvedApplicationURL = (
            applicationURL ?? Bundle.main.bundleURL
        ).standardizedFileURL
        self.applicationURL = resolvedApplicationURL
        if environment.mode == .release {
            self.serviceManager = serviceManager ?? ServiceManager(
                appURL: resolvedApplicationURL,
                supportURL: environment.supportURL
            )
        } else {
            self.serviceManager = serviceManager
        }
        self.serviceHealthProvider =
            serviceHealthProvider ?? UnavailableSetupServiceHealthProvider()
        self.fileManager = fileManager
        self.logOpener = logOpener ?? { NSWorkspace.shared.open($0) }
        self.ownerProfileInspector = resolvedOwnerProfileInspector
        self.progress = nil
        self.currentError = nil
        self.permissionStates = [:]
        self.currentStep = restoredStep
        self.hasCompletedOnboarding = storedRecord.isComplete
        self.serviceStatus = nil
        self.enrollmentLifecycle = .idle
        self.recoveryStep = storedRecord.isComplete && !durableOwnerEvidence
            ? (initialInspection.isValid ? .safetyTest : .enrollment)
            : nil
        self.ownerProfileValid = initialInspection.isValid
        self.diagnosisPassed = durableOwnerEvidence
        self.ownerTestPassed = durableOwnerEvidence
        self.currentOwnerFingerprint = initialInspection.fingerprint
        self.runtimeValidationRequired = !durableOwnerEvidence
        let initialReadiness = SetupReadiness.evaluate(
            permissions: [:],
            ownerProfileValid: self.ownerProfileValid,
            diagnosisPassed: self.diagnosisPassed,
            ownerTestPassed: self.ownerTestPassed,
            serviceHealthy: false
        )
        self.readiness = initialReadiness
        self.checks = initialReadiness.checks
        if restoredStep != storedRecord.currentStep {
            let repairedRecord = OnboardingRecord(
                currentStep: restoredStep,
                completedSteps: storedRecord.completedSteps,
                completedAt: nil,
                appVersion: storedRecord.appVersion
            )
            try? setupStore.save(repairedRecord)
            self.hasCompletedOnboarding = false
        }
    }

    var isLiveReady: Bool {
        readiness.canEnableProtection
    }

    func refreshLiveReadiness() async {
        refreshStaticOwnerProfileEvidence()
        await refreshPermissions()
        await refreshServiceHealthForEnable()
        updateReadiness()
        updateCompletedRecoveryState()
    }

    func refreshCurrentAuthorizationStatus() async {
        refreshStaticOwnerProfileEvidence()
        await refreshPermissions()
        await refreshServiceHealthForEnable()
        updateReadiness()
        updateCompletedRecoveryState()
    }

    func refreshPermissions() async {
        permissionStates = await permissionCenter.refresh()
        updateReadiness()
    }

    func requestPermission(_ permission: SetupPermission) async {
        currentError = nil
        switch permission {
        case .camera:
            await permissionCenter.requestCamera()
        case .inputMonitoring:
            permissionCenter.requestInputMonitoring()
        case .accessibility:
            permissionCenter.requestAccessibility()
        case .screenRecording:
            permissionCenter.requestScreenRecording()
        }
        await refreshPermissions()
    }

    func openPermissionSettings(_ permission: SetupPermission) {
        permissionCenter.openSettings(for: permission)
    }

    func setPermissionStepVisible(_ visible: Bool) {
        permissionCenter.setPermissionStepVisible(visible)
    }

    @discardableResult
    func prepareForSetup() async -> Bool {
        currentError = nil
        let issues = preparationIssues()
        guard issues.isEmpty else {
            currentError = issues.joined(separator: " ")
            return false
        }
        do {
            try persistStep(.permissions, completing: .preparation)
            await refreshPermissions()
            return true
        } catch {
            currentError = "无法保存准备检查结果，请检查应用支持目录权限后重试。"
            return false
        }
    }

    @discardableResult
    func continueFromPermissions() async -> Bool {
        await refreshPermissions()
        let requiredPermissions: [SetupPermission] = [.camera]
        guard requiredPermissions.allSatisfy({
            permissionStates[$0] == .granted
        }) else {
            currentError = "请先完成控制中心的摄像头授权。"
            return false
        }
        do {
            try persistStep(.enrollment, completing: .permissions)
            currentError = nil
            return true
        } catch {
            currentError = "无法保存权限检查结果，请检查应用支持目录权限后重试。"
            return false
        }
    }

    func goBack() {
        let previous: SetupStep?
        switch currentStep {
        case .preparation:
            previous = nil
        case .permissions:
            previous = .preparation
        case .enrollment:
            previous = .permissions
        case .safetyTest:
            previous = .enrollment
        case .completion:
            previous = .safetyTest
        }
        guard let previous else {
            return
        }
        do {
            try persistStep(previous)
            currentError = nil
        } catch {
            currentError = "无法保存当前设置步骤，请稍后重试。"
        }
    }

    func startEnrollment() async {
        guard enrollmentLifecycle == .idle, enrollmentTask == nil else {
            return
        }
        enrollmentLifecycle = .running
        await acquireRuntimeReadinessPermit()
        guard enrollmentLifecycle == .running else {
            releaseRuntimeReadinessPermit()
            enrollmentLifecycle = .idle
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
            enrollmentLifecycle = .idle
            releaseRuntimeReadinessPermit()
        }

        do {
            let result = try await task.value
            applyEnrollment(result.events, generation: generation)
            guard handleExitCode(result.exitCode) else {
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
            refreshStaticOwnerProfileEvidence()
            guard ownerProfileValid else {
                currentError = "录入结束但未找到本人人脸资料，请重新录入。"
                updateReadiness()
                return
            }
            try markEnrollmentCompleted()
            currentError = nil
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
        guard enrollmentLifecycle == .running else {
            return
        }
        enrollmentLifecycle = .cancelling
        enrollmentGeneration = nil
        progress = nil
        let task = enrollmentTask
        task?.cancel()
    }

    func runDiagnosis() async {
        await acquireRuntimeReadinessPermit()
        defer { releaseRuntimeReadinessPermit() }
        await probeRuntimeDiagnosis()
        await refreshServiceAfterDiagnosis()
        updateReadiness()
    }

    private func refreshServiceAfterDiagnosis() async {
        if environment.mode == .release {
            await installAndRefreshReleaseService()
        } else {
            serviceHealthy = await serviceHealthProvider.isServiceHealthy()
        }
    }

    private func probeRuntimeDiagnosis() async {
        currentError = nil
        diagnosisPassed = false
        runtimeValidationRequired = true
        refreshStaticOwnerProfileEvidence()
        do {
            let result = try await runtimeRunner.run(command: .diagnose) { _ in }
            diagnosisPassed = result.exitCode == 0
                && result.events.contains {
                    $0.event == "diagnosis_complete" && $0.status == "success"
                }
            if let templateCheck = result.events.last(where: {
                $0.event == "diagnosis_check" && $0.check == "template"
            }) {
                ownerProfileValid = templateCheck.status == "success"
                if !ownerProfileValid {
                    currentOwnerFingerprint = nil
                    ownerTestPassed = false
                }
            }
            if !handleExitCode(result.exitCode) {
                diagnosisPassed = false
            }
        } catch {
            currentError = localizedRuntimeError(error)
            diagnosisPassed = false
        }
        updateReadiness()
    }

    @discardableResult
    func runSafetyTest() async -> Bool {
        await acquireRuntimeReadinessPermit()
        defer { releaseRuntimeReadinessPermit() }
        await probeRuntimeDiagnosis()
        await refreshServiceAfterDiagnosis()
        guard diagnosisPassed else {
            return false
        }
        await verifyOwnerWithoutLockingInsidePermit()
        updateReadiness()
        guard readiness.canEnableProtection else {
            if currentError == nil {
                currentError = "安全测试尚未全部通过，请修复未通过的项目后重试。"
            }
            return false
        }
        do {
            runtimeValidationRequired = false
            recoveryStep = nil
            if hasCompletedOnboarding {
                try persistCompletedEvidencePreservingHistory()
            } else {
                try persistStep(.completion, completing: .safetyTest)
            }
            currentError = nil
            return true
        } catch {
            currentError = "无法保存安全测试结果，请检查应用支持目录权限后重试。"
            return false
        }
    }

    func verifyOwnerWithoutLocking() async {
        guard enrollmentTask == nil, enrollmentLifecycle == .idle else {
            ownerTestPassed = false
            currentError = "本人录入正在进行，请完成或取消录入后再测试。"
            updateReadiness()
            return
        }
        await acquireRuntimeReadinessPermit()
        defer { releaseRuntimeReadinessPermit() }
        await verifyOwnerWithoutLockingInsidePermit()
    }

    private func verifyOwnerWithoutLockingInsidePermit() async {
        guard enrollmentTask == nil else {
            ownerTestPassed = false
            currentError = "本人录入正在进行，请完成或取消录入后再测试。"
            updateReadiness()
            return
        }
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
            if ownerTestPassed, diagnosisPassed, ownerProfileValid {
                runtimeValidationRequired = false
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

    func enableProtection() async throws {
        guard enrollmentLifecycle == .idle else {
            let error = SetupCoordinatorError.notReady([.ownerProfile])
            currentError = "本人录入仍在结束处理中，请稍后再试。"
            throw error
        }
        await acquireRuntimeReadinessPermit()
        defer { releaseRuntimeReadinessPermit() }
        currentError = nil
        await refreshPermissions()
        await probeRuntimeDiagnosis()
        if diagnosisPassed {
            await verifyOwnerWithoutLockingInsidePermit()
        }
        await refreshServiceHealthForEnable()
        await refreshPermissions()
        updateReadiness()
        let missingChecks = readiness.requiredChecks
            .filter { readiness.checks[$0] != true }
            .sorted { $0.rawValue < $1.rawValue }
        guard missingChecks.isEmpty else {
            do {
                _ = try localStore.writeControl(enabled: false)
            } catch {
                let coordinatorError = SetupCoordinatorError.persistenceFailed
                currentError = coordinatorError.localizedDescription
                throw coordinatorError
            }
            let error = SetupCoordinatorError.notReady(missingChecks)
            fallBackForFailedEnable(missingChecks)
            if currentError?.contains("无法保存安全恢复步骤") != true {
                currentError = error.localizedDescription
            }
            throw error
        }

        let previousRecord = setupStore.record
        let completedRecord = OnboardingRecord(
            currentStep: .completion,
            completedSteps: SetupStep.allCases,
            completedAt: previousRecord.isComplete
                ? previousRecord.completedAt
                : ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            ownerProfileFingerprint: currentOwnerFingerprint,
            requiresOwnerReverification: false
        )
        do {
            try setupStore.save(completedRecord)
            _ = try localStore.writeControl(enabled: true)
            currentStep = completedRecord.currentStep
            hasCompletedOnboarding = completedRecord.isComplete
            recoveryStep = nil
            runtimeValidationRequired = false
            currentError = nil
        } catch {
            try? setupStore.save(previousRecord)
            let coordinatorError = SetupCoordinatorError.persistenceFailed
            currentError = coordinatorError.localizedDescription
            throw coordinatorError
        }
    }

    func restartService() async {
        guard let serviceManager else {
            currentError = "当前安装没有可管理的后台服务。"
            return
        }
        currentError = nil
        do {
            try await serviceManager.restart()
            await refreshServiceHealthForEnable()
        } catch {
            recordDiagnosticError(error, operation: "restart_service")
            currentError = localizedRuntimeError(error)
            serviceHealthy = false
        }
        updateReadiness()
    }

    func reinstallService() async {
        guard let serviceManager else {
            currentError = "当前安装没有可管理的后台服务。"
            return
        }
        currentError = nil
        do {
            _ = try localStore.writeControl(enabled: false)
            try await serviceManager.install(
                appURL: applicationURL,
                supportURL: environment.supportURL
            )
            await refreshServiceHealthForEnable()
        } catch {
            recordDiagnosticError(error, operation: "reinstall_service")
            currentError = localizedRuntimeError(error)
            serviceHealthy = false
        }
        updateReadiness()
    }

    @discardableResult
    func openLogs() -> Bool {
        let logsURL = environment.logsURL
        do {
            try fileManager.createDirectory(
                at: logsURL,
                withIntermediateDirectories: true
            )
        } catch {
            currentError = "无法访问日志文件夹，请检查本地文件权限后重试。"
            return false
        }
        guard logOpener(logsURL) else {
            currentError = "无法打开日志文件夹，请稍后重试。"
            return false
        }
        currentError = nil
        return true
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
            appVersion: appVersion,
            ownerProfileFingerprint: currentOwnerFingerprint,
            requiresOwnerReverification: true
        )
        try setupStore.save(record)
        currentStep = record.currentStep
        hasCompletedOnboarding = record.isComplete
    }

    private func persistStep(
        _ step: SetupStep,
        completing completedStep: SetupStep? = nil
    ) throws {
        var completedSteps = setupStore.record.completedSteps
        if let completedStep, !completedSteps.contains(completedStep) {
            completedSteps.append(completedStep)
        }
        let record = OnboardingRecord(
            currentStep: step,
            completedSteps: completedSteps,
            completedAt: nil,
            appVersion: appVersion,
            ownerProfileFingerprint: currentOwnerFingerprint,
            requiresOwnerReverification: true
        )
        try setupStore.save(record)
        currentStep = step
        hasCompletedOnboarding = false
    }

    private func persistCompletedEvidencePreservingHistory() throws {
        let previous = setupStore.record
        let record = OnboardingRecord(
            currentStep: .completion,
            completedSteps: previous.completedSteps,
            completedAt: previous.completedAt,
            appVersion: appVersion,
            ownerProfileFingerprint: currentOwnerFingerprint,
            requiresOwnerReverification: false
        )
        try setupStore.save(record)
        currentStep = .completion
        hasCompletedOnboarding = true
    }

    private func refreshStaticOwnerProfileEvidence() {
        let inspection = ownerProfileInspector.inspect(
            environment.dataURL.appendingPathComponent("owner_face.npy")
        )
        currentOwnerFingerprint = inspection.fingerprint
        ownerProfileValid = inspection.isValid
        guard inspection.isValid else {
            diagnosisPassed = false
            ownerTestPassed = false
            runtimeValidationRequired = true
            if hasCompletedOnboarding {
                recoveryStep = .enrollment
            }
            return
        }
        let record = setupStore.record
        let fingerprintMatches = record.ownerProfileFingerprint != nil
            && record.ownerProfileFingerprint == inspection.fingerprint
        if record.requiresOwnerReverification == true || !fingerprintMatches {
            ownerTestPassed = false
            runtimeValidationRequired = true
            if hasCompletedOnboarding {
                recoveryStep = .safetyTest
            }
            return
        }
        if record.isComplete && !runtimeValidationRequired {
            diagnosisPassed = true
            ownerTestPassed = true
            recoveryStep = nil
        }
    }

    private func preparationIssues() -> [String] {
        var issues: [String] = []
#if !arch(arm64)
        issues.append("此版本仅支持 Apple Silicon Mac。")
#endif
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)
        ) {
            issues.append("需要 macOS 12 或更高版本。")
        }
        do {
            try fileManager.createDirectory(
                at: environment.supportURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: environment.dataURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: environment.logsURL,
                withIntermediateDirectories: true
            )
        } catch {
            issues.append("应用支持目录不可写。")
        }
        guard environment.mode == .release else {
            return issues
        }
        let applicationPath = applicationURL.standardizedFileURL.path
        let userApplicationsPath = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path
        let isInApplications = applicationPath.hasPrefix("/Applications/")
            || applicationPath.hasPrefix(userApplicationsPath + "/")
        if !isInApplications {
            issues.append("请先将应用移到“应用程序”文件夹。")
        }
        if !fileManager.isExecutableFile(atPath: environment.runtimeExecutableURL.path) {
            issues.append("内置运行组件不完整，请重新下载应用。")
        }
        return issues
    }

    private static func safeRestoredStep(
        for record: OnboardingRecord,
        ownerProfileValid: Bool
    ) -> SetupStep {
        guard !record.isComplete else {
            return .completion
        }
        let completed = Set(record.completedSteps)
        let furthestSafeStep: SetupStep
        if !completed.contains(.preparation) {
            furthestSafeStep = .preparation
        } else if !completed.contains(.permissions) {
            furthestSafeStep = .permissions
        } else if !completed.contains(.enrollment) || !ownerProfileValid {
            furthestSafeStep = .enrollment
        } else if !completed.contains(.safetyTest) {
            furthestSafeStep = .safetyTest
        } else {
            furthestSafeStep = .completion
        }
        let order = SetupStep.allCases
        guard let currentIndex = order.firstIndex(of: record.currentStep),
              let furthestIndex = order.firstIndex(of: furthestSafeStep) else {
            return .preparation
        }
        return order[min(currentIndex, furthestIndex)]
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
        if let serviceError = error as? ServiceManagerError {
            switch serviceError {
            case .invalidTemplate:
                return "后台服务配置无效，请重新安装应用。"
            case .commandFailed, .commandTimedOut:
                return "后台服务操作未完成，请稍后重试；若仍失败，请重新安装服务。"
            case .unstableService:
                return "后台服务尚未稳定，请确认 Agent 权限后重试。"
            case .rollbackFailed:
                return "后台服务更新未完成，旧设置恢复也遇到问题；保护保持关闭。"
            }
        }
        if let error = error as? LocalizedError,
           let description = error.errorDescription {
            return description
        }
        return "运行组件未能完成，请重新运行诊断。"
    }

    private func fallBackForFailedEnable(_ missingChecks: [SetupCheck]) {
        let missing = Set(missingChecks)
        if hasCompletedOnboarding {
            if missing.contains(.cameraPermission)
                || missing.contains(.screenRecordingPermission) {
                invalidateDurableOwnerEvidenceAfterPermissionRevocation()
                recoveryStep = .permissions
            } else if missing.contains(.ownerProfile) {
                recoveryStep = .enrollment
            } else if missing.contains(.diagnosis) || missing.contains(.ownerTest) {
                recoveryStep = .safetyTest
            } else {
                recoveryStep = .completion
            }
            return
        }
        do {
            if missing.contains(.cameraPermission)
                || missing.contains(.screenRecordingPermission) {
                try persistStep(.permissions)
            } else if missing.contains(.ownerProfile) {
                try persistStep(.enrollment)
            } else if missing.contains(.diagnosis) || missing.contains(.ownerTest) {
                try persistStep(.safetyTest)
            }
        } catch {
            currentError = "无法保存安全恢复步骤，请稍后重试。"
        }
    }

    private func updateCompletedRecoveryState() {
        guard hasCompletedOnboarding else {
            return
        }
        guard readiness.checks[.cameraPermission] == true else {
            invalidateDurableOwnerEvidenceAfterPermissionRevocation()
            recoveryStep = .permissions
            return
        }
        if !ownerProfileValid {
            recoveryStep = .enrollment
        } else if setupStore.record.requiresOwnerReverification == true
                    || !ownerTestPassed
                    || !diagnosisPassed {
            recoveryStep = .safetyTest
        } else if !serviceHealthy {
            recoveryStep = .completion
        } else {
            recoveryStep = nil
        }
    }

    private func invalidateDurableOwnerEvidenceAfterPermissionRevocation() {
        ownerTestPassed = false
        runtimeValidationRequired = true
        let previous = setupStore.record
        guard previous.isComplete,
              previous.requiresOwnerReverification != true else {
            return
        }
        let updated = OnboardingRecord(
            currentStep: previous.currentStep,
            completedSteps: previous.completedSteps,
            completedAt: previous.completedAt,
            appVersion: previous.appVersion,
            ownerProfileFingerprint: previous.ownerProfileFingerprint,
            requiresOwnerReverification: true
        )
        do {
            try setupStore.save(updated)
        } catch {
            currentError = "无法保存安全恢复状态，请稍后重试。"
        }
    }

    private func recordDiagnosticError(_ error: Error, operation: String) {
        do {
            try fileManager.createDirectory(
                at: environment.logsURL,
                withIntermediateDirectories: true
            )
            let url = environment.logsURL.appendingPathComponent("ui-diagnostics.log")
            let line = [
                ISO8601DateFormatter().string(from: Date()),
                operation,
                String(describing: error),
            ].joined(separator: " | ") + "\n"
            let data = Data(line.utf8)
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // Diagnostics are best-effort; customer-facing errors stay sanitized.
        }
    }

    private func acquireRuntimeReadinessPermit() async {
        if !runtimeReadinessBusy {
            runtimeReadinessBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            runtimeReadinessWaiters.append(continuation)
        }
    }

    private func releaseRuntimeReadinessPermit() {
        guard !runtimeReadinessWaiters.isEmpty else {
            runtimeReadinessBusy = false
            return
        }
        runtimeReadinessWaiters.removeFirst().resume()
    }

    private func updateReadiness() {
        let evaluated = SetupReadiness.evaluate(
            permissions: permissionStates,
            agentPermissions: agentPermissionStates,
            ownerProfileValid: ownerProfileValid,
            diagnosisPassed: diagnosisPassed,
            ownerTestPassed: ownerTestPassed,
            serviceHealthy: serviceHealthy
        )
        readiness = evaluated
        checks = evaluated.checks
    }

    private var agentPermissionStates: [SetupPermission: PermissionState] {
        if environment.mode == .source {
            return permissionStates
        }
        guard let serviceStatus else {
            return [
                .camera: .notDetermined,
                .inputMonitoring: .notDetermined,
                .accessibility: .notDetermined,
            ]
        }
        return [
            .camera: serviceStatus.cameraReady ? .granted : .denied,
            .inputMonitoring:
                serviceStatus.inputMonitoringReady ? .granted : .denied,
            .accessibility:
                serviceStatus.accessibilityReady ? .granted : .denied,
        ]
    }

    private func refreshServiceHealthForEnable() async {
        if environment.mode == .release {
            guard let serviceManager else {
                serviceHealthy = false
                return
            }
            let serviceStatus = await serviceManager.status()
            self.serviceStatus = serviceStatus
            serviceHealthy = serviceStatus.isHealthy
            switch serviceStatus.state {
            case .healthy:
                break
            case .needsRepair:
                currentError = "应用位置已变化，请重新安装后台服务后再开启保护。"
            case .notInstalled:
                currentError = "后台服务尚未安装，请重新运行诊断。"
            case .unhealthy:
                currentError = "后台 Agent 权限或运行状态未就绪，请完成授权并重新运行诊断。"
            }
        } else {
            serviceHealthy = await serviceHealthProvider.isServiceHealthy()
            serviceStatus = nil
        }
    }

    private func installAndRefreshReleaseService() async {
        serviceHealthy = false
        guard diagnosisPassed, let serviceManager else {
            return
        }
        do {
            _ = try localStore.writeControl(enabled: false)
            try await serviceManager.install(
                appURL: applicationURL,
                supportURL: environment.supportURL
            )
            let serviceStatus = await serviceManager.status()
            self.serviceStatus = serviceStatus
            serviceHealthy = serviceStatus.isHealthy
            switch serviceStatus.state {
            case .healthy:
                break
            case .needsRepair:
                currentError = "应用位置已变化，请重新安装后台服务后再开启保护。"
            case .notInstalled:
                currentError = "后台服务尚未安装，请重新运行诊断。"
            case .unhealthy:
                currentError = "后台 Agent 权限或运行状态未就绪，请完成授权并重新运行诊断。"
            }
        } catch {
            serviceHealthy = false
            serviceStatus = nil
            _ = try? localStore.writeControl(enabled: false)
            recordDiagnosticError(error, operation: "install_service")
            currentError = localizedRuntimeError(error)
        }
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
