import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

private struct LegacyCleanupDiagnosticReport: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let state: String
    let reason: String
    let agentPlistPresent: Bool
    let statusPlistPresent: Bool
    let cleanupRecordPresent: Bool

    static func ambiguous(
        metadata: LegacyCleanupDiagnosticMetadata
    ) -> LegacyCleanupDiagnosticReport {
        LegacyCleanupDiagnosticReport(
            schemaVersion: schemaVersion,
            state: "blocked",
            reason: "legacy_structure_ambiguous",
            agentPlistPresent: metadata.agentPlistPresent,
            statusPlistPresent: metadata.statusPlistPresent,
            cleanupRecordPresent: metadata.cleanupRecordPresent
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(self)
    }
}

struct OwnerProfileInspection: Equatable {
    let isValid: Bool
    let fingerprint: String?
}

private enum EnrollmentOwnerSnapshot {
    case absent
    case present(Data)
}

private struct EnrollmentOwnerEvidenceSnapshot {
    let ownerProfileValid: Bool
    let diagnosisPassed: Bool
    let ownerTestPassed: Bool
    let recoveryStep: SetupStep?
    let currentOwnerFingerprint: String?
    let runtimeValidationRequired: Bool
}

private enum OwnerProfileTransactionError: Error {
    case unsafeEntry
    case byteLimitExceeded
    case systemCall(String, Int32)
}

protocol OwnerProfileInspecting: AnyObject {
    func inspect(_ url: URL) -> OwnerProfileInspection
}

final class NumpyOwnerProfileInspector: OwnerProfileInspecting {
    private let maximumBytes = 67_108_864
    private let maximumHeaderBytes = 10_000
    private let expectedColumns = 9_216

    func inspect(_ url: URL) -> OwnerProfileInspection {
        guard let data = try? Data(
            contentsOf: url,
            options: [.mappedIfSafe]
        ), data.count >= 10, data.count <= maximumBytes,
              Array(data.prefix(6)) == [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59] else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let major = data[6]
        guard data[7] == 0 else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let headerStart: Int
        let headerLength: Int
        if major == 1, data.count >= 10 {
            headerStart = 10
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
        } else if (major == 2 || major == 3), data.count >= 12 {
            headerStart = 12
            let rawHeaderLength = UInt32(data[8])
                | (UInt32(data[9]) << 8)
                | (UInt32(data[10]) << 16)
                | (UInt32(data[11]) << 24)
            guard let convertedHeaderLength = Int(exactly: rawHeaderLength) else {
                return OwnerProfileInspection(isValid: false, fingerprint: nil)
            }
            headerLength = convertedHeaderLength
        } else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let payloadStartResult = headerStart.addingReportingOverflow(headerLength)
        guard headerLength > 0, headerLength <= maximumHeaderBytes,
              !payloadStartResult.overflow,
              payloadStartResult.partialValue <= data.count else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let payloadStart = payloadStartResult.partialValue
        let headerBytes = Array(data[headerStart..<payloadStart])
        guard var parser = NumpyHeaderParser(bytes: headerBytes),
              let metadata = parser.parse(),
              metadata.descr == "<f4",
              metadata.fortranOrder == false else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let shape = metadata.shape
        guard
              shape.rows >= 2,
              shape.columns == expectedColumns else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let valueCount = shape.rows.multipliedReportingOverflow(by: shape.columns)
        guard !valueCount.overflow else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let payloadBytes = valueCount.partialValue.multipliedReportingOverflow(by: 4)
        guard !payloadBytes.overflow else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let payloadEnd = payloadStart.addingReportingOverflow(
            payloadBytes.partialValue
        )
        guard !payloadEnd.overflow, payloadEnd.partialValue == data.count else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        var bits: UInt32 = 0
        var byteIndex = 0
        for byte in data[payloadStart..<payloadEnd.partialValue] {
            switch byteIndex {
            case 0:
                bits = UInt32(byte)
                byteIndex = 1
            case 1:
                bits |= UInt32(byte) << 8
                byteIndex = 2
            case 2:
                bits |= UInt32(byte) << 16
                byteIndex = 3
            case 3:
                bits |= UInt32(byte) << 24
                guard Float(bitPattern: bits).isFinite else {
                    return OwnerProfileInspection(isValid: false, fingerprint: nil)
                }
                bits = 0
                byteIndex = 0
            default:
                return OwnerProfileInspection(isValid: false, fingerprint: nil)
            }
        }
        guard byteIndex == 0 else {
            return OwnerProfileInspection(isValid: false, fingerprint: nil)
        }
        let fingerprint = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return OwnerProfileInspection(isValid: true, fingerprint: fingerprint)
    }
}

private struct NumpyHeaderParser {
    struct Metadata {
        let descr: String
        let fortranOrder: Bool
        let shape: (rows: Int, columns: Int)
    }

    private let bytes: [UInt8]
    private var index = 0

    init?(bytes: [UInt8]) {
        guard bytes.allSatisfy({ $0 < 0x80 }) else {
            return nil
        }
        self.bytes = bytes
    }

    mutating func parse() -> Metadata? {
        skipWhitespace()
        guard consume(0x7B) else {
            return nil
        }
        var descr: String?
        var fortranOrder: Bool?
        var shape: (rows: Int, columns: Int)?
        var seenKeys = Set<String>()

        while true {
            skipWhitespace()
            if consume(0x7D) {
                break
            }
            guard let key = parseString(), seenKeys.insert(key).inserted else {
                return nil
            }
            skipWhitespace()
            guard consume(0x3A) else {
                return nil
            }
            skipWhitespace()
            switch key {
            case "descr":
                guard let value = parseString() else {
                    return nil
                }
                descr = value
            case "fortran_order":
                guard let value = parseBoolean() else {
                    return nil
                }
                fortranOrder = value
            case "shape":
                guard let value = parseShape() else {
                    return nil
                }
                shape = value
            default:
                return nil
            }
            skipWhitespace()
            if consume(0x2C) {
                continue
            }
            guard consume(0x7D) else {
                return nil
            }
            break
        }
        skipWhitespace()
        guard index == bytes.count, seenKeys.count == 3,
              let descr, let fortranOrder, let shape else {
            return nil
        }
        return Metadata(
            descr: descr,
            fortranOrder: fortranOrder,
            shape: shape
        )
    }

    private mutating func parseString() -> String? {
        guard index < bytes.count,
              bytes[index] == 0x27 || bytes[index] == 0x22 else {
            return nil
        }
        let quote = bytes[index]
        guard advance() else {
            return nil
        }
        let start = index
        while index < bytes.count, bytes[index] != quote {
            guard bytes[index] != 0x5C else {
                return nil
            }
            guard advance() else {
                return nil
            }
        }
        guard index < bytes.count else {
            return nil
        }
        let value = String(decoding: bytes[start..<index], as: UTF8.self)
        guard advance() else {
            return nil
        }
        return value
    }

    private mutating func parseBoolean() -> Bool? {
        if consumeLiteral("False") {
            return false
        }
        if consumeLiteral("True") {
            return true
        }
        return nil
    }

    private mutating func parseShape() -> (rows: Int, columns: Int)? {
        guard consume(0x28) else {
            return nil
        }
        skipWhitespace()
        guard let rows = parseUnsignedInteger() else {
            return nil
        }
        skipWhitespace()
        guard consume(0x2C) else {
            return nil
        }
        skipWhitespace()
        guard let columns = parseUnsignedInteger() else {
            return nil
        }
        skipWhitespace()
        _ = consume(0x2C)
        skipWhitespace()
        guard consume(0x29) else {
            return nil
        }
        return (rows, columns)
    }

    private mutating func parseUnsignedInteger() -> Int? {
        guard index < bytes.count else {
            return nil
        }
        if bytes[index] == 0x30 {
            guard advance() else {
                return nil
            }
            guard index == bytes.count
                    || bytes[index] < 0x30
                    || bytes[index] > 0x39 else {
                return nil
            }
            return 0
        }
        guard bytes[index] >= 0x31, bytes[index] <= 0x39 else {
            return nil
        }
        var value = 0
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            let multiplied = value.multipliedReportingOverflow(by: 10)
            guard !multiplied.overflow else {
                return nil
            }
            let added = multiplied.partialValue.addingReportingOverflow(
                Int(bytes[index] - 0x30)
            )
            guard !added.overflow else {
                return nil
            }
            value = added.partialValue
            guard advance() else {
                return nil
            }
        }
        return value
    }

    private mutating func consumeLiteral(_ literal: String) -> Bool {
        let literalBytes = Array(literal.utf8)
        let end = index.addingReportingOverflow(literalBytes.count)
        guard !end.overflow, end.partialValue <= bytes.count,
              Array(bytes[index..<end.partialValue]) == literalBytes else {
            return false
        }
        index = end.partialValue
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20
                || bytes[index] == 0x09
                || bytes[index] == 0x0A
                || bytes[index] == 0x0D {
            guard advance() else {
                return
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else {
            return false
        }
        return advance()
    }

    private mutating func advance() -> Bool {
        let next = index.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue <= bytes.count else {
            return false
        }
        index = next.partialValue
        return true
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

private struct RuntimeReadinessWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
}

private struct ServiceMutationWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
}

private final class EnrollmentRuntimeStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var cancelled = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var childTask: Task<RuntimeResult, Error>?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func waitUntilOpened() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                } else if opened {
                    lock.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func open() {
        let continuation: CheckedContinuation<Bool, Never>?
        let shouldStart: Bool
        lock.lock()
        if cancelled {
            shouldStart = false
        } else {
            opened = true
            shouldStart = true
        }
        continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: shouldStart)
    }

    func bind(_ task: Task<RuntimeResult, Error>) {
        let shouldCancel: Bool
        lock.lock()
        childTask = task
        shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func unbind() {
        lock.lock()
        childTask = nil
        lock.unlock()
    }

    func cancel() {
        let continuation: CheckedContinuation<Bool, Never>?
        let task: Task<RuntimeResult, Error>?
        lock.lock()
        cancelled = true
        continuation = waiter
        waiter = nil
        task = childTask
        lock.unlock()
        task?.cancel()
        continuation?.resume(returning: false)
    }
}

private final class UnavailableSetupServiceHealthProvider: SetupServiceHealthProviding {
    func isServiceHealthy() async -> Bool {
        false
    }
}

@MainActor
final class SetupCoordinator: ObservableObject {
    private static let ownerProfileMaximumBytes = 67_108_864

    @Published private(set) var progress: Double?
    @Published private(set) var currentError: String?
    @Published private(set) var permissionStates: [SetupPermission: PermissionState]
    @Published private(set) var checks: [SetupCheck: Bool]
    @Published private(set) var readiness: SetupReadiness
    @Published private(set) var currentStep: SetupStep
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var serviceStatus: ServiceStatus?
    @Published private(set) var enrollmentLifecycle: EnrollmentLifecycle
    @Published private(set) var enrollmentPose: String?
    @Published private(set) var enrollmentQuality: String?
    @Published private(set) var enrollmentRejectionReason: String?
    @Published private(set) var recoveryStep: SetupStep?
    @Published private(set) var legacyCleanupState: LegacyCleanupState
    @Published private(set) var legacyOrphanRecoveryAvailable = false
    @Published private(set) var isQuitting = false

    private let environment: AppEnvironment
    private let permissionCenter: PermissionCenter
    private let setupStore: SetupStore
    private let localStore: LocalJSONStore
    private let runtimeRunner: RuntimeCommandRunning
    private let serviceManager: ServiceManaging?
    private let legacyInstallCleaner: LegacyInstallCleaning?
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
    private var enrollmentTaskGeneration: UUID?
    private var activeRuntimeTask: (
        id: UUID,
        task: Task<RuntimeResult, Error>
    )?
    private var enrollmentRollbackFailed = false
    private var enrollmentGeneration: UUID?
    private var enrollmentStartGate: EnrollmentRuntimeStartGate?
    private var enrollmentPermitWaiterID: UUID?
    private var profileRevision: UInt64 = 0
    private var currentOwnerFingerprint: String?
    private var runtimeValidationRequired: Bool
    private var runtimeReadinessBusy = false
    private var runtimeReadinessWaiters: [RuntimeReadinessWaiter] = []
    private var serviceMutationBusy = false
    private var serviceMutationWaiters: [ServiceMutationWaiter] = []
    private var confirmedLegacyCandidate: LegacyCleanupCandidate?
    private var legacyOrphanRecoveryCandidate: LegacyOrphanRecoveryCandidate?
    private var legacyCleanupGeneration: UInt64 = 0

    init(
        environment: AppEnvironment,
        permissionCenter: PermissionCenter,
        setupStore: SetupStore,
        localStore: LocalJSONStore,
        runtimeRunner: RuntimeCommandRunning? = nil,
        serviceManager: ServiceManaging? = nil,
        legacyInstallCleaner: LegacyInstallCleaning? = nil,
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
            self.legacyInstallCleaner = legacyInstallCleaner
                ?? LegacyInstallCleaner(
                    appURL: resolvedApplicationURL,
                    supportURL: environment.supportURL
                )
            self.legacyCleanupState = .unchecked
        } else {
            self.serviceManager = serviceManager
            self.legacyInstallCleaner = nil
            self.legacyCleanupState = .notRequired
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
        self.enrollmentPose = nil
        self.enrollmentQuality = nil
        self.enrollmentRejectionReason = nil
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
        !isQuitting
            && legacyCleanupAllowsServiceAccess
            && readiness.canEnableProtection
    }

    var requiresLegacyCleanupAttention: Bool {
        environment.mode == .release && !legacyCleanupAllowsServiceAccess
    }

    func inspectLegacyInstall() async {
        guard environment.mode == .release,
              legacyCleanupState == .unchecked,
              let legacyInstallCleaner else {
            return
        }
        let inspection = legacyInstallCleaner.inspect()
        let orphanCandidate: LegacyOrphanRecoveryCandidate?
        if case .ambiguous = inspection {
            orphanCandidate = legacyInstallCleaner.inspectRecoverableOrphan()
        } else {
            orphanCandidate = nil
        }
        applyLegacyInspection(
            inspection,
            orphanCandidate: orphanCandidate
        )
    }

    func recheckLegacyInstall() async {
        guard environment.mode == .release,
              case .ambiguous = legacyCleanupState,
              legacyInstallCleaner != nil else {
            return
        }
        publishLegacyCleanupState(.unchecked)
        await inspectLegacyInstall()
    }

    @discardableResult
    func recoverKnownLegacyOrphan() async -> Bool {
        guard environment.mode == .release,
              case .ambiguous = legacyCleanupState,
              let candidate = legacyOrphanRecoveryCandidate,
              let legacyInstallCleaner else {
            return false
        }
        publishLegacyCleanupState(.cleaning)
        let generation = legacyCleanupGeneration
        let result = await legacyInstallCleaner.removeRecoverableOrphan(candidate)
        guard legacyCleanupGeneration == generation,
              legacyCleanupState == .cleaning else {
            publishBlockedLegacyCleanupEffects()
            return false
        }
        let nextCandidate: LegacyOrphanRecoveryCandidate?
        if case .ambiguous = result {
            nextCandidate = legacyInstallCleaner.inspectRecoverableOrphan()
        } else {
            nextCandidate = nil
        }
        applyLegacyInspection(result, orphanCandidate: nextCandidate)
        if result == .notFound {
            currentError = nil
            return true
        }
        return false
    }

    func legacyDiagnosticData() -> Data? {
        guard case .ambiguous = legacyCleanupState,
              let legacyInstallCleaner else {
            return nil
        }
        let report = LegacyCleanupDiagnosticReport.ambiguous(
            metadata: legacyInstallCleaner.diagnosticMetadata()
        )
        return try? report.encoded()
    }

    @discardableResult
    func copyLegacyDiagnostics() -> Bool {
        guard let data = legacyDiagnosticData(),
              let text = String(data: data, encoding: .utf8) else {
            currentError = "当前没有可导出的旧版诊断摘要。"
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(text, forType: .string)
        currentError = copied ? nil : "无法复制诊断摘要，请尝试保存文件。"
        return copied
    }

    @discardableResult
    func saveLegacyDiagnostics() -> Bool {
        guard let data = legacyDiagnosticData() else {
            currentError = "当前没有可导出的旧版诊断摘要。"
            return false
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mac-face-lock-legacy-diagnostic.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            return false
        }
        do {
            try data.write(to: destination, options: .atomic)
            currentError = nil
            return true
        } catch {
            currentError = "无法保存诊断摘要，请选择其他位置后重试。"
            return false
        }
    }

    @discardableResult
    func openLegacyResolutionGuide() -> Bool {
        let guide = environment.resourcesURL.appendingPathComponent(
            "help/legacy-install-resolution.md"
        )
        guard fileManager.isReadableFile(atPath: guide.path) else {
            currentError = "处理指南缺失，请重新安装发行版。"
            return false
        }
        let opened = NSWorkspace.shared.open(guide)
        currentError = opened ? nil : "无法打开处理指南，请重新安装发行版。"
        return opened
    }

    @discardableResult
    func confirmLegacyCleanup() async -> Bool {
        guard case .confirmationRequired = legacyCleanupState,
              let candidate = confirmedLegacyCandidate,
              let legacyInstallCleaner else {
            currentError = "没有可确认的旧版清理任务。"
            return false
        }
        publishLegacyCleanupState(.cleaning)
        let generation = legacyCleanupGeneration
        let result = await legacyInstallCleaner.clean(candidate)
        guard legacyCleanupGeneration == generation,
              legacyCleanupState == .cleaning else {
            publishBlockedLegacyCleanupEffects()
            return false
        }
        if result == .notFound {
            confirmedLegacyCandidate = nil
            return completeLegacyCleanupAndResetSetup()
        }
        applyLegacyInspection(result)
        return legacyCleanupAllowsServiceAccess
    }

    @discardableResult
    func retryLegacyCleanup() async -> Bool {
        guard case .cleanupIncomplete = legacyCleanupState,
              let legacyInstallCleaner else {
            currentError = "没有可重试的旧版清理任务。"
            return false
        }
        publishLegacyCleanupState(.cleaning)
        let generation = legacyCleanupGeneration
        let result = await legacyInstallCleaner.retry()
        guard legacyCleanupGeneration == generation,
              legacyCleanupState == .cleaning else {
            publishBlockedLegacyCleanupEffects()
            return false
        }
        if result == .notFound {
            confirmedLegacyCandidate = nil
            return completeLegacyCleanupAndResetSetup()
        }
        applyLegacyInspection(result)
        return legacyCleanupAllowsServiceAccess
    }

    func cancelLegacyCleanup() {
        guard case .confirmationRequired = legacyCleanupState else {
            return
        }
        currentError = "已取消旧版清理；完成清理前不会启用发行版保护。"
    }

    func refreshLiveReadiness() async {
        await ensureLegacyInspectionCompleted()
        refreshStaticOwnerProfileEvidence()
        await refreshPermissions()
        await refreshServiceHealthForEnable()
        updateReadiness()
        updateCompletedRecoveryState()
    }

    func refreshCurrentAuthorizationStatus() async {
        await ensureLegacyInspectionCompleted()
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
        if legacyCleanupState == .unchecked {
            await inspectLegacyInstall()
        }
        guard guardLegacyCleanupGate() else {
            return false
        }
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
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        let generation = UUID()
        let startGate = EnrollmentRuntimeStartGate()
        await withTaskCancellationHandler {
            await startEnrollment(
                generation: generation,
                startGate: startGate
            )
        } onCancel: { [weak self] in
            startGate.cancel()
            Task { @MainActor [weak self] in
                self?.cancelEnrollment(generation: generation)
            }
        }
    }

    private func startEnrollment(
        generation: UUID,
        startGate: EnrollmentRuntimeStartGate
    ) async {
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        guard enrollmentLifecycle == .idle, enrollmentTask == nil else {
            return
        }
        enrollmentLifecycle = .running
        enrollmentGeneration = generation
        enrollmentStartGate = startGate
        let acquiredPermit = await acquireRuntimeReadinessPermit { [weak self] id in
            self?.enrollmentPermitWaiterID = id
        }
        enrollmentPermitWaiterID = nil
        guard acquiredPermit else {
            if enrollmentGeneration == generation {
                enrollmentGeneration = nil
            }
            if enrollmentStartGate === startGate {
                enrollmentStartGate = nil
            }
            enrollmentLifecycle = .idle
            return
        }
        guard !Task.isCancelled, !startGate.isCancelled, !isQuitting,
              enrollmentLifecycle == .running else {
            releaseRuntimeReadinessPermit()
            if enrollmentGeneration == generation {
                enrollmentGeneration = nil
            }
            if enrollmentStartGate === startGate {
                enrollmentStartGate = nil
            }
            enrollmentLifecycle = .idle
            return
        }
        let ownerSnapshot: EnrollmentOwnerSnapshot
        do {
            ownerSnapshot = try captureEnrollmentOwnerSnapshot()
            enrollmentRollbackFailed = false
        } catch {
            currentError = "无法安全准备本人人脸资料，请检查本地数据目录后重试。"
            releaseRuntimeReadinessPermit()
            enrollmentGeneration = nil
            enrollmentStartGate = nil
            enrollmentLifecycle = .idle
            return
        }
        let ownerEvidenceSnapshot = captureEnrollmentOwnerEvidence()
        profileRevision &+= 1
        currentError = nil
        progress = 0
        enrollmentPose = "front"
        enrollmentQuality = nil
        enrollmentRejectionReason = nil
        ownerTestPassed = false
        updateReadiness()

        guard !Task.isCancelled, !startGate.isCancelled,
              enrollmentLifecycle == .running else {
            enrollmentGeneration = nil
            enrollmentStartGate = nil
            progress = nil
            releaseRuntimeReadinessPermit()
            enrollmentLifecycle = .idle
            return
        }
        let task = Task { [runtimeRunner, startGate] in
            guard await startGate.waitUntilOpened() else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            guard !startGate.isCancelled else {
                throw CancellationError()
            }
            return try await runtimeRunner.run(command: .enroll) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.applyEnrollment(event, generation: generation)
                }
            }
        }
        enrollmentTask = task
        enrollmentTaskGeneration = generation
        activeRuntimeTask = (generation, task)
        startGate.bind(task)
        if Task.isCancelled || startGate.isCancelled {
            startGate.cancel()
            task.cancel()
        } else {
            startGate.open()
        }
        var retainEnrolledOwner = false
        defer {
            startGate.unbind()
            if enrollmentTaskGeneration == generation {
                enrollmentTask = nil
                enrollmentTaskGeneration = nil
            }
            if activeRuntimeTask?.id == generation {
                activeRuntimeTask = nil
            }
            if enrollmentGeneration == generation {
                enrollmentGeneration = nil
            }
            if enrollmentStartGate === startGate {
                enrollmentStartGate = nil
            }
            enrollmentLifecycle = .idle
            releaseRuntimeReadinessPermit()
        }
        defer {
            if retainEnrolledOwner {
                enrollmentRollbackFailed = false
            } else {
                do {
                    try restoreEnrollmentOwnerSnapshot(ownerSnapshot)
                    restoreEnrollmentOwnerEvidence(ownerEvidenceSnapshot)
                    refreshStaticOwnerProfileEvidence()
                    updateReadiness()
                    enrollmentRollbackFailed = false
                } catch {
                    enrollmentRollbackFailed = true
                    currentError = "未能恢复原有本人人脸资料，保护保持关闭，请重新打开应用后重试。"
                }
            }
        }

        do {
            let result = try await task.value
            try Task.checkCancellation()
            guard !rejectMutationDuringApplicationQuit() else {
                return
            }
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
            guard !rejectMutationDuringApplicationQuit() else {
                return
            }
            try Task.checkCancellation()
            try markEnrollmentCompleted()
            retainEnrolledOwner = true
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
        guard let generation = enrollmentGeneration
                ?? enrollmentTaskGeneration else {
            return
        }
        cancelEnrollment(generation: generation)
    }

    private func cancelEnrollment(generation: UUID) {
        guard enrollmentGeneration == generation
                || enrollmentTaskGeneration == generation else {
            return
        }
        enrollmentLifecycle = .cancelling
        if enrollmentGeneration == generation {
            enrollmentGeneration = nil
        }
        progress = nil
        enrollmentStartGate?.cancel()
        if let waiterID = enrollmentPermitWaiterID {
            enrollmentPermitWaiterID = nil
            cancelRuntimeReadinessWaiter(id: waiterID)
        }
        if enrollmentTaskGeneration == generation {
            enrollmentTask?.cancel()
        }
    }

    private func cancelAndDrainRuntimeForApplicationQuit() async -> Bool {
        if let generation = enrollmentGeneration
                ?? enrollmentTaskGeneration {
            cancelEnrollment(generation: generation)
        }
        activeRuntimeTask?.task.cancel()

        guard await acquireRuntimeReadinessPermit() else {
            return false
        }
        let rollbackSucceeded = !enrollmentRollbackFailed
        releaseRuntimeReadinessPermit()
        return rollbackSucceeded
    }

    func runDiagnosis() async {
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        let cleanupGeneration = legacyCleanupAccessGeneration
        guard await acquireRuntimeReadinessPermit() else {
            return
        }
        defer { releaseRuntimeReadinessPermit() }
        guard !Task.isCancelled,
              !rejectMutationDuringApplicationQuit() else {
            return
        }
        await probeRuntimeDiagnosis()
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        await refreshServiceAfterDiagnosis(
            expectedCleanupGeneration: cleanupGeneration
        )
        updateReadiness()
    }

    private func refreshServiceAfterDiagnosis(
        expectedCleanupGeneration: UInt64?
    ) async {
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        if environment.mode == .release {
            guard await acquireServiceMutationPermit() else {
                return
            }
            defer { releaseServiceMutationPermit() }
            guard !rejectMutationDuringApplicationQuit() else {
                return
            }
            await installAndRefreshReleaseService(
                expectedCleanupGeneration: expectedCleanupGeneration
            )
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
            let result = try await runRuntimeCommand(command: .diagnose) { _ in }
            guard !rejectMutationDuringApplicationQuit() else {
                return
            }
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
            if isQuitting {
                _ = rejectMutationDuringApplicationQuit()
                diagnosisPassed = false
                updateReadiness()
                return
            }
            currentError = localizedRuntimeError(error)
            diagnosisPassed = false
        }
        updateReadiness()
    }

    @discardableResult
    func runSafetyTest() async -> Bool {
        guard !rejectMutationDuringApplicationQuit() else {
            return false
        }
        let cleanupGeneration = legacyCleanupAccessGeneration
        guard await acquireRuntimeReadinessPermit() else {
            return false
        }
        defer { releaseRuntimeReadinessPermit() }
        guard !Task.isCancelled,
              !rejectMutationDuringApplicationQuit() else {
            return false
        }
        await probeRuntimeDiagnosis()
        guard !rejectMutationDuringApplicationQuit() else {
            return false
        }
        await refreshServiceAfterDiagnosis(
            expectedCleanupGeneration: cleanupGeneration
        )
        guard !rejectMutationDuringApplicationQuit() else {
            return false
        }
        guard diagnosisPassed else {
            return false
        }
        await verifyOwnerWithoutLockingInsidePermit()
        guard !rejectMutationDuringApplicationQuit() else {
            return false
        }
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
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        guard enrollmentTask == nil, enrollmentLifecycle == .idle else {
            ownerTestPassed = false
            currentError = "本人录入正在进行，请完成或取消录入后再测试。"
            updateReadiness()
            return
        }
        guard await acquireRuntimeReadinessPermit() else {
            return
        }
        defer { releaseRuntimeReadinessPermit() }
        guard !Task.isCancelled,
              !rejectMutationDuringApplicationQuit() else {
            return
        }
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
            let result = try await runRuntimeCommand(command: .verifyOwner) { _ in }
            guard !rejectMutationDuringApplicationQuit() else {
                return
            }
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
            if isQuitting {
                _ = rejectMutationDuringApplicationQuit()
                ownerTestPassed = false
                updateReadiness()
                return
            }
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
        try rejectProtectionEnableDuringApplicationQuit()
        await ensureLegacyInspectionCompleted()
        try rejectProtectionEnableDuringApplicationQuit()
        guard let cleanupGeneration = legacyCleanupAccessGeneration else {
            publishBlockedLegacyCleanupEffects()
            throw SetupCoordinatorError.notReady([.serviceHealth])
        }
        guard enrollmentLifecycle == .idle else {
            let error = SetupCoordinatorError.notReady([.ownerProfile])
            currentError = "本人录入仍在结束处理中，请稍后再试。"
            throw error
        }
        guard await acquireRuntimeReadinessPermit() else {
            throw CancellationError()
        }
        defer { releaseRuntimeReadinessPermit() }
        try rejectProtectionEnableDuringApplicationQuit()
        guard await acquireServiceMutationPermit() else {
            throw CancellationError()
        }
        defer { releaseServiceMutationPermit() }
        try rejectProtectionEnableDuringApplicationQuit()
        guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
            publishBlockedLegacyCleanupEffects()
            throw SetupCoordinatorError.notReady([.serviceHealth])
        }
        try Task.checkCancellation()
        currentError = nil
        await refreshPermissions()
        try rejectProtectionEnableDuringApplicationQuit()
        guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
            publishBlockedLegacyCleanupEffects()
            throw SetupCoordinatorError.notReady([.serviceHealth])
        }
        await probeRuntimeDiagnosis()
        try rejectProtectionEnableDuringApplicationQuit()
        guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
            publishBlockedLegacyCleanupEffects()
            throw SetupCoordinatorError.notReady([.serviceHealth])
        }
        if diagnosisPassed {
            await verifyOwnerWithoutLockingInsidePermit()
            try rejectProtectionEnableDuringApplicationQuit()
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                throw SetupCoordinatorError.notReady([.serviceHealth])
            }
        }
        await refreshServiceHealthForEnable(
            expectedCleanupGeneration: cleanupGeneration
        )
        try rejectProtectionEnableDuringApplicationQuit()
        guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
            publishBlockedLegacyCleanupEffects()
            throw SetupCoordinatorError.notReady([.serviceHealth])
        }
        await refreshPermissions()
        try rejectProtectionEnableDuringApplicationQuit()
        guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
            publishBlockedLegacyCleanupEffects()
            throw SetupCoordinatorError.notReady([.serviceHealth])
        }
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
            try rejectProtectionEnableDuringApplicationQuit()
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                throw SetupCoordinatorError.notReady([.serviceHealth])
            }
            try setupStore.save(completedRecord)
            try rejectProtectionEnableDuringApplicationQuit()
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                throw SetupCoordinatorError.notReady([.serviceHealth])
            }
            _ = try localStore.writeControl(enabled: true)
            currentStep = completedRecord.currentStep
            hasCompletedOnboarding = completedRecord.isComplete
            recoveryStep = nil
            runtimeValidationRequired = false
            currentError = nil
        } catch {
            try? setupStore.save(previousRecord)
            if isQuitting {
                _ = try? localStore.writeControl(enabled: false)
                _ = rejectMutationDuringApplicationQuit()
                throw SetupCoordinatorError.notReady([.serviceHealth])
            }
            let coordinatorError = SetupCoordinatorError.persistenceFailed
            currentError = coordinatorError.localizedDescription
            throw coordinatorError
        }
    }

    func restartService() async {
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        guard await acquireServiceMutationPermit() else {
            return
        }
        defer { releaseServiceMutationPermit() }
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        guard let cleanupGeneration = legacyCleanupAccessGeneration else {
            publishBlockedLegacyCleanupEffects()
            return
        }
        guard let serviceManager else {
            currentError = "当前安装没有可管理的后台服务。"
            return
        }
        currentError = nil
        do {
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return
            }
            try await serviceManager.restart()
            guard !rejectMutationDuringApplicationQuit() else {
                return
            }
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return
            }
            await refreshServiceHealthForEnable(
                expectedCleanupGeneration: cleanupGeneration
            )
        } catch {
            recordDiagnosticError(error, operation: "restart_service")
            currentError = localizedRuntimeError(error)
            serviceHealthy = false
        }
        updateReadiness()
    }

    func reinstallService() async {
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        guard await acquireServiceMutationPermit() else {
            return
        }
        defer { releaseServiceMutationPermit() }
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        guard let cleanupGeneration = legacyCleanupAccessGeneration else {
            publishBlockedLegacyCleanupEffects()
            return
        }
        guard let serviceManager else {
            currentError = "当前安装没有可管理的后台服务。"
            return
        }
        currentError = nil
        do {
            _ = try localStore.writeControl(enabled: false)
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return
            }
            try await serviceManager.install(
                appURL: applicationURL,
                supportURL: environment.supportURL
            )
            guard !rejectMutationDuringApplicationQuit() else {
                return
            }
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return
            }
            await refreshServiceHealthForEnable(
                expectedCleanupGeneration: cleanupGeneration
            )
        } catch {
            recordDiagnosticError(error, operation: "reinstall_service")
            currentError = localizedRuntimeError(error)
            serviceHealthy = false
        }
        updateReadiness()
    }

    @discardableResult
    func uninstallServicePreservingData() async -> Bool {
        guard !rejectMutationDuringApplicationQuit() else {
            return false
        }
        guard await acquireServiceMutationPermit() else {
            return false
        }
        defer { releaseServiceMutationPermit() }
        guard !rejectMutationDuringApplicationQuit() else {
            return false
        }
        return await uninstallServicePreservingDataInsidePermit()
    }

    @discardableResult
    func stopBackgroundForApplicationQuit() async -> Bool {
        guard !isQuitting else {
            return false
        }
        isQuitting = true
        serviceHealthy = false
        updateReadiness()

        do {
            _ = try localStore.writeControl(enabled: false)
        } catch {
            currentError = SetupCoordinatorError.persistenceFailed.localizedDescription
            isQuitting = false
            updateReadiness()
            return false
        }

        guard await cancelAndDrainRuntimeForApplicationQuit() else {
            _ = try? localStore.writeControl(enabled: false)
            isQuitting = false
            updateReadiness()
            return false
        }

        guard await acquireServiceMutationPermit() else {
            _ = try? localStore.writeControl(enabled: false)
            isQuitting = false
            updateReadiness()
            return false
        }
        let stopped = await uninstallServicePreservingDataInsidePermit()
        releaseServiceMutationPermit()

        guard stopped else {
            _ = try? localStore.writeControl(enabled: false)
            isQuitting = false
            updateReadiness()
            return false
        }
        return true
    }

    private func uninstallServicePreservingDataInsidePermit() async -> Bool {
        currentError = nil
        do {
            _ = try localStore.writeControl(enabled: false)
            guard let cleanupGeneration = legacyCleanupAccessGeneration else {
                publishBlockedLegacyCleanupEffects()
                return false
            }
            guard let serviceManager else {
                currentError = "当前安装没有可管理的后台服务。"
                return false
            }
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return false
            }
            let stoppedStatus = try await serviceManager.uninstallPreservingData()
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return false
            }
            serviceStatus = stoppedStatus
            serviceHealthy = false
            updateReadiness()

            let controlWasDisabled =
                !localStore.readControl().protectionEnabled
            let serviceWasStopped =
                stoppedStatus.state == .notInstalled
                && stoppedStatus.pid == nil
            guard controlWasDisabled && serviceWasStopped else {
                _ = try? localStore.writeControl(enabled: false)
                currentError = controlWasDisabled
                    ? "未能确认后台保护已经停止，请修复后重试退出。"
                    : "检测到保护状态在退出期间发生变化，已保持保护关闭，请重试退出。"
                return false
            }
            return true
        } catch {
            _ = try? localStore.writeControl(enabled: false)
            recordDiagnosticError(error, operation: "uninstall_service_preserving_data")
            currentError = localizedRuntimeError(error)
            serviceHealthy = false
            updateReadiness()
            return false
        }
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

    private func captureEnrollmentOwnerEvidence()
        -> EnrollmentOwnerEvidenceSnapshot
    {
        EnrollmentOwnerEvidenceSnapshot(
            ownerProfileValid: ownerProfileValid,
            diagnosisPassed: diagnosisPassed,
            ownerTestPassed: ownerTestPassed,
            recoveryStep: recoveryStep,
            currentOwnerFingerprint: currentOwnerFingerprint,
            runtimeValidationRequired: runtimeValidationRequired
        )
    }

    private func restoreEnrollmentOwnerEvidence(
        _ snapshot: EnrollmentOwnerEvidenceSnapshot
    ) {
        ownerProfileValid = snapshot.ownerProfileValid
        diagnosisPassed = snapshot.diagnosisPassed
        ownerTestPassed = snapshot.ownerTestPassed
        recoveryStep = snapshot.recoveryStep
        currentOwnerFingerprint = snapshot.currentOwnerFingerprint
        runtimeValidationRequired = snapshot.runtimeValidationRequired
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
        guard !isQuitting,
              enrollmentGeneration == generation else {
            return
        }
        if event.event == "enrollment_complete", event.status == "success" {
            progress = 1
            enrollmentQuality = "accepted"
            enrollmentRejectionReason = nil
            return
        }
        guard event.event == "enrollment_progress",
              let captured = event.capturedSamples,
              let required = event.requiredSamples,
              required > 0 else {
            return
        }
        progress = min(max(Double(captured) / Double(required), 0), 1)
        enrollmentPose = event.pose
        enrollmentQuality = event.quality
        enrollmentRejectionReason = event.reason
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
                return "后台服务尚未稳定，请确认 Mac Face Lock 权限后重试。"
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

    private func captureEnrollmentOwnerSnapshot() throws
        -> EnrollmentOwnerSnapshot
    {
        try fileManager.createDirectory(
            at: environment.dataURL,
            withIntermediateDirectories: true
        )
        let directoryFD = try openOwnerDataDirectory()
        defer { Darwin.close(directoryFD) }

        let fileFD = openat(
            directoryFD,
            "owner_face.npy",
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileFD >= 0 else {
            if errno == ENOENT {
                return .absent
            }
            throw OwnerProfileTransactionError.systemCall("openat", errno)
        }
        defer { Darwin.close(fileFD) }

        let fileSize = try validateOwnerProfileFile(fileFD)
        var data = Data()
        data.reserveCapacity(fileSize)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(fileFD, &buffer, buffer.count)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw OwnerProfileTransactionError.systemCall("read", errno)
            }
            let nextCount = data.count.addingReportingOverflow(Int(count))
            guard !nextCount.overflow,
                  nextCount.partialValue <= Self.ownerProfileMaximumBytes else {
                throw OwnerProfileTransactionError.byteLimitExceeded
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        guard data.count == fileSize else {
            throw OwnerProfileTransactionError.unsafeEntry
        }
        return .present(data)
    }

    private func restoreEnrollmentOwnerSnapshot(
        _ snapshot: EnrollmentOwnerSnapshot
    ) throws {
        let directoryFD = try openOwnerDataDirectory()
        defer { Darwin.close(directoryFD) }

        switch snapshot {
        case .absent:
            try validateCurrentOwnerEntryIfPresent(directoryFD)
            if unlinkat(directoryFD, "owner_face.npy", 0) != 0 {
                guard errno == ENOENT else {
                    throw OwnerProfileTransactionError.systemCall(
                        "unlinkat",
                        errno
                    )
                }
                return
            }
            guard fsync(directoryFD) == 0 else {
                throw OwnerProfileTransactionError.systemCall("fsync", errno)
            }
        case .present(let data):
            guard data.count <= Self.ownerProfileMaximumBytes else {
                throw OwnerProfileTransactionError.byteLimitExceeded
            }
            try validateCurrentOwnerEntryIfPresent(directoryFD)
            let temporaryName =
                ".owner_face.rollback.\(UUID().uuidString).tmp"
            let temporaryFD = openat(
                directoryFD,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            guard temporaryFD >= 0 else {
                throw OwnerProfileTransactionError.systemCall("openat", errno)
            }
            var published = false
            defer {
                Darwin.close(temporaryFD)
                if !published {
                    _ = unlinkat(directoryFD, temporaryName, 0)
                }
            }
            guard fchmod(temporaryFD, 0o600) == 0 else {
                throw OwnerProfileTransactionError.systemCall("fchmod", errno)
            }
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return
                }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(
                        temporaryFD,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if count < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw OwnerProfileTransactionError.systemCall(
                            "write",
                            errno
                        )
                    }
                    guard count > 0 else {
                        throw OwnerProfileTransactionError.systemCall(
                            "write",
                            EIO
                        )
                    }
                    offset += count
                }
            }
            guard fsync(temporaryFD) == 0 else {
                throw OwnerProfileTransactionError.systemCall("fsync", errno)
            }
            guard renameat(
                directoryFD,
                temporaryName,
                directoryFD,
                "owner_face.npy"
            ) == 0 else {
                throw OwnerProfileTransactionError.systemCall("renameat", errno)
            }
            published = true
            guard fsync(directoryFD) == 0 else {
                throw OwnerProfileTransactionError.systemCall("fsync", errno)
            }

            let restoredFD = openat(
                directoryFD,
                "owner_face.npy",
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard restoredFD >= 0 else {
                throw OwnerProfileTransactionError.systemCall("openat", errno)
            }
            defer { Darwin.close(restoredFD) }
            let restoredSize = try validateOwnerProfileFile(restoredFD)
            guard restoredSize == data.count else {
                throw OwnerProfileTransactionError.unsafeEntry
            }
            var restoredData = Data()
            restoredData.reserveCapacity(restoredSize)
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = Darwin.read(restoredFD, &buffer, buffer.count)
                if count == 0 {
                    break
                }
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw OwnerProfileTransactionError.systemCall(
                        "read",
                        errno
                    )
                }
                restoredData.append(
                    contentsOf: buffer.prefix(Int(count))
                )
            }
            guard restoredData == data else {
                throw OwnerProfileTransactionError.unsafeEntry
            }
        }
    }

    private func openOwnerDataDirectory() throws -> Int32 {
        let directoryFD = Darwin.open(
            environment.dataURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            throw OwnerProfileTransactionError.systemCall("open", errno)
        }
        var info = stat()
        guard fstat(directoryFD, &info) == 0 else {
            let savedErrno = errno
            Darwin.close(directoryFD)
            throw OwnerProfileTransactionError.systemCall(
                "fstat",
                savedErrno
            )
        }
        guard info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else {
            Darwin.close(directoryFD)
            throw OwnerProfileTransactionError.unsafeEntry
        }
        return directoryFD
    }

    private func validateOwnerProfileFile(_ fileFD: Int32) throws -> Int {
        var info = stat()
        guard fstat(fileFD, &info) == 0 else {
            throw OwnerProfileTransactionError.systemCall("fstat", errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              UInt64(info.st_size) <= UInt64(Self.ownerProfileMaximumBytes),
              let size = Int(exactly: info.st_size) else {
            throw OwnerProfileTransactionError.unsafeEntry
        }
        return size
    }

    private func validateCurrentOwnerEntryIfPresent(
        _ directoryFD: Int32
    ) throws {
        var info = stat()
        guard fstatat(
            directoryFD,
            "owner_face.npy",
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return
            }
            throw OwnerProfileTransactionError.systemCall("fstatat", errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1 else {
            throw OwnerProfileTransactionError.unsafeEntry
        }
    }

    private func runRuntimeCommand(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult {
        let id = UUID()
        let task = Task { [runtimeRunner] in
            try await runtimeRunner.run(
                command: command,
                onEvent: onEvent
            )
        }
        activeRuntimeTask = (id, task)
        defer {
            if activeRuntimeTask?.id == id {
                activeRuntimeTask = nil
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }

    private func acquireRuntimeReadinessPermit(
        onQueued: ((UUID) -> Void)? = nil
    ) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        if !runtimeReadinessBusy {
            runtimeReadinessBusy = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                runtimeReadinessWaiters.append(
                    RuntimeReadinessWaiter(
                        id: id,
                        continuation: continuation
                    )
                )
                onQueued?(id)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelRuntimeReadinessWaiter(id: id)
            }
        }
    }

    private func releaseRuntimeReadinessPermit() {
        guard !runtimeReadinessWaiters.isEmpty else {
            runtimeReadinessBusy = false
            return
        }
        runtimeReadinessWaiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancelRuntimeReadinessWaiter(id: UUID) {
        guard let index = runtimeReadinessWaiters.firstIndex(where: {
            $0.id == id
        }) else {
            return
        }
        let waiter = runtimeReadinessWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func acquireServiceMutationPermit() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        if !serviceMutationBusy {
            serviceMutationBusy = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                serviceMutationWaiters.append(
                    ServiceMutationWaiter(
                        id: id,
                        continuation: continuation
                    )
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelServiceMutationWaiter(id: id)
            }
        }
    }

    private func releaseServiceMutationPermit() {
        guard !serviceMutationWaiters.isEmpty else {
            serviceMutationBusy = false
            return
        }
        serviceMutationWaiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancelServiceMutationWaiter(id: UUID) {
        guard let index = serviceMutationWaiters.firstIndex(where: {
            $0.id == id
        }) else {
            return
        }
        let waiter = serviceMutationWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    @discardableResult
    private func rejectMutationDuringApplicationQuit() -> Bool {
        guard isQuitting else {
            return false
        }
        _ = try? localStore.writeControl(enabled: false)
        serviceHealthy = false
        currentError = "正在退出 Mac Face Lock，后台保护操作已停止。"
        updateReadiness()
        return true
    }

    private func rejectProtectionEnableDuringApplicationQuit() throws {
        guard rejectMutationDuringApplicationQuit() else {
            return
        }
        throw SetupCoordinatorError.notReady([.serviceHealth])
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

    private var legacyCleanupAllowsServiceAccess: Bool {
        environment.mode == .source
            || legacyCleanupState == .notRequired
            || legacyCleanupState == .completed
    }

    private var legacyCleanupAccessGeneration: UInt64? {
        legacyCleanupAllowsServiceAccess ? legacyCleanupGeneration : nil
    }

    private func isLegacyCleanupAccessCurrent(_ generation: UInt64) -> Bool {
        legacyCleanupAllowsServiceAccess
            && legacyCleanupGeneration == generation
    }

    private func ensureLegacyInspectionCompleted() async {
        guard environment.mode == .release,
              legacyCleanupState == .unchecked else {
            return
        }
        await inspectLegacyInstall()
    }

    private func guardLegacyCleanupGate() -> Bool {
        guard legacyCleanupAllowsServiceAccess else {
            publishBlockedLegacyCleanupEffects()
            return false
        }
        return true
    }

    private func publishLegacyCleanupState(
        _ state: LegacyCleanupState,
        confirmedCandidate: LegacyCleanupCandidate? = nil,
        orphanCandidate: LegacyOrphanRecoveryCandidate? = nil
    ) {
        legacyCleanupGeneration &+= 1
        confirmedLegacyCandidate = confirmedCandidate
        legacyOrphanRecoveryCandidate = orphanCandidate
        legacyOrphanRecoveryAvailable = orphanCandidate != nil
        legacyCleanupState = state
        if !legacyCleanupAllowsServiceAccess {
            publishBlockedLegacyCleanupEffects()
        } else {
            updateReadiness()
        }
    }

    private func publishBlockedLegacyCleanupEffects() {
        serviceHealthy = false
        serviceStatus = nil
        do {
            try setupStore.disableProtectionForLegacyCleanup()
        } catch {
            currentError = "无法保持保护关闭，请检查应用支持目录权限后重试。"
            updateReadiness()
            return
        }
        currentError = "请先完成旧版清理，再继续设置后台保护。"
        updateReadiness()
    }

    private func applyLegacyInspection(
        _ inspection: LegacyCleanupInspection,
        orphanCandidate: LegacyOrphanRecoveryCandidate? = nil
    ) {
        switch inspection {
        case .confirmed(let candidate):
            publishLegacyCleanupState(
                .confirmationRequired,
                confirmedCandidate: candidate
            )
        case .notFound:
            publishLegacyCleanupState(.notRequired)
        case .ambiguous(let message):
            publishLegacyCleanupState(
                .ambiguous(message),
                orphanCandidate: orphanCandidate
            )
        case .cleanupIncomplete(let message):
            publishLegacyCleanupState(.cleanupIncomplete(message))
        case .completed:
            _ = completeLegacyCleanupAndResetSetup()
        }
    }

#if TESTING
    func applyLegacyInspectionForTesting(_ inspection: LegacyCleanupInspection) {
        applyLegacyInspection(inspection)
    }
#endif

    private func completeLegacyCleanupAndResetSetup() -> Bool {
        let freshRecord = OnboardingRecord(
            currentStep: .preparation,
            completedSteps: [],
            completedAt: nil,
            appVersion: appVersion,
            ownerProfileFingerprint: nil,
            requiresOwnerReverification: true
        )
        do {
            try setupStore.save(freshRecord)
        } catch {
            publishLegacyCleanupState(
                .cleanupIncomplete(
                    "旧版清理已完成，但无法重置首次设置状态。"
                )
            )
            currentError = "无法重置首次设置状态，请重试清理。"
            return false
        }
        currentStep = .preparation
        hasCompletedOnboarding = false
        recoveryStep = nil
        diagnosisPassed = false
        ownerTestPassed = false
        serviceHealthy = false
        serviceStatus = nil
        runtimeValidationRequired = true
        do {
            try setupStore.disableProtectionForLegacyCleanup()
            guard let legacyInstallCleaner else {
                throw SetupCoordinatorError.persistenceFailed
            }
            try legacyInstallCleaner.acknowledgeCompletion()
        } catch {
            publishLegacyCleanupState(
                .cleanupIncomplete(
                    "旧版清理已完成，但无法确认重置结果。"
                )
            )
            currentError = "无法确认旧版清理重置结果，请重试清理。"
            return false
        }
        publishLegacyCleanupState(.completed)
        currentError = nil
        updateReadiness()
        return true
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

    private func refreshServiceHealthForEnable(
        expectedCleanupGeneration: UInt64? = nil
    ) async {
        guard let cleanupGeneration = legacyCleanupAccessGeneration,
              expectedCleanupGeneration == nil
                || expectedCleanupGeneration == cleanupGeneration else {
            publishBlockedLegacyCleanupEffects()
            return
        }
        if environment.mode == .release {
            guard let serviceManager else {
                serviceHealthy = false
                return
            }
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return
            }
            let serviceStatus = await serviceManager.status()
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return
            }
            self.serviceStatus = serviceStatus
            serviceHealthy = serviceStatus.isHealthy
            switch serviceStatus.state {
            case .healthy:
                break
            case .needsRepair:
                if shouldPublishServiceRepair {
                    currentError = "应用位置已变化，请重新安装后台服务后再开启保护。"
                }
            case .notInstalled:
                if shouldPublishServiceRepair {
                    currentError = "后台服务尚未安装，请重新运行诊断。"
                }
            case .unhealthy:
                if shouldPublishServiceRepair {
                    currentError = "Mac Face Lock 权限或后台运行状态未就绪，请完成授权并重新运行诊断。"
                }
            }
        } else {
            serviceHealthy = await serviceHealthProvider.isServiceHealthy()
            serviceStatus = nil
        }
    }

    private func installAndRefreshReleaseService(
        expectedCleanupGeneration: UInt64?
    ) async {
        serviceHealthy = false
        guard !rejectMutationDuringApplicationQuit() else {
            return
        }
        guard let cleanupGeneration = legacyCleanupAccessGeneration,
              expectedCleanupGeneration == nil
                || expectedCleanupGeneration == cleanupGeneration else {
            publishBlockedLegacyCleanupEffects()
            return
        }
        guard let serviceManager else {
            return
        }
        do {
            _ = try localStore.writeControl(enabled: false)
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return
            }
            try await serviceManager.install(
                appURL: applicationURL,
                supportURL: environment.supportURL
            )
            guard !rejectMutationDuringApplicationQuit() else {
                return
            }
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return
            }
            let serviceStatus = await serviceManager.status()
            guard !rejectMutationDuringApplicationQuit() else {
                return
            }
            guard isLegacyCleanupAccessCurrent(cleanupGeneration) else {
                publishBlockedLegacyCleanupEffects()
                return
            }
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
                currentError = "Mac Face Lock 权限或后台运行状态未就绪，请完成授权并重新运行诊断。"
            }
        } catch {
            serviceHealthy = false
            serviceStatus = nil
            _ = try? localStore.writeControl(enabled: false)
            recordDiagnosticError(error, operation: "install_service")
            currentError = localizedRuntimeError(error)
        }
    }

    private var shouldPublishServiceRepair: Bool {
        hasCompletedOnboarding
            || currentStep == .safetyTest
            || currentStep == .completion
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
        case 13:
            return "录入超时，请保持脸部居中并按照当前动作重试。"
        case 20:
            return "运行组件发生错误，请重新运行诊断；若仍失败，请重新安装应用。"
        default:
            return "运行组件异常退出（代码 \(exitCode)），请重新运行诊断。"
        }
    }
}
