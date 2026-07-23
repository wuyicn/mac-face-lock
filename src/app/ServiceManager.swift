import Darwin
import CoreFoundation
import Foundation

enum ServiceState: String, Codable, Equatable {
    case notInstalled = "not_installed"
    case unhealthy
    case healthy
    case needsRepair = "needs_repair"
}

struct ServiceStatus: Equatable {
    let state: ServiceState
    let pid: Int32?
    let cameraReady: Bool
    let inputMonitoringReady: Bool
    let accessibilityReady: Bool
    let installedProgram: String?
    let expectedProgram: String
    let heartbeatTimestamp: String?
    let heartbeatSequence: UInt64?
    let isResponsive: Bool

    init(
        state: ServiceState,
        pid: Int32?,
        cameraReady: Bool,
        inputMonitoringReady: Bool,
        accessibilityReady: Bool,
        installedProgram: String?,
        expectedProgram: String,
        heartbeatTimestamp: String? = nil,
        heartbeatSequence: UInt64? = nil,
        isResponsive: Bool = false
    ) {
        self.state = state
        self.pid = pid
        self.cameraReady = cameraReady
        self.inputMonitoringReady = inputMonitoringReady
        self.accessibilityReady = accessibilityReady
        self.installedProgram = installedProgram
        self.expectedProgram = expectedProgram
        self.heartbeatTimestamp = heartbeatTimestamp
        self.heartbeatSequence = heartbeatSequence
        self.isResponsive = isResponsive
    }

    var isHealthy: Bool {
        state == .healthy
    }
}

protocol ServiceManaging: AnyObject {
    func install(appURL: URL, supportURL: URL) async throws
    func status() async -> ServiceStatus
    func restart() async throws
    func uninstallPreservingData() async throws -> ServiceStatus
}

struct ServiceCommandResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

protocol ServiceCommandRunning: AnyObject {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ServiceCommandResult
}

protocol ServiceFileSystem: AnyObject {
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func createDirectory(at url: URL) throws
    func writeAtomically(_ data: Data, to url: URL) throws
    func replaceItem(at destinationURL: URL, withItemAt temporaryURL: URL) throws
    func removeItem(at url: URL) throws
}

enum ServiceManagerError: Error, LocalizedError {
    case invalidTemplate
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case commandTimedOut(command: String)
    case unstableService
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTemplate:
            return "后台服务配置无效，请重新安装应用。"
        case .commandFailed(let command, let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(command) 失败（代码 \(exitCode)）。"
                : "\(command) 失败（代码 \(exitCode)）：\(detail)"
        case .commandTimedOut(let command):
            return "\(command) 超时，后台服务未完成更新。"
        case .unstableService:
            return "后台服务未能稳定启动，请修复权限或重新安装服务。"
        case .rollbackFailed(let detail):
            return "后台服务更新失败，且旧服务恢复失败：\(detail)"
        }
    }
}

final class FoundationServiceFileSystem: ServiceFileSystem {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func replaceItem(at destinationURL: URL, withItemAt temporaryURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

final class BoundedServiceCommandRunner: ServiceCommandRunning {
    private let outputLimit = 64 * 1_024

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ServiceCommandResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let totalTimeout = max(timeout, 0)
        let deadline = startedAt + totalTimeout
        let terminationGrace = min(0.25, totalTimeout)
        let executionDeadline = deadline - terminationGrace
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        while process.isRunning {
            let remaining = executionDeadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                break
            }
            try await Task.sleep(
                nanoseconds: min(
                    25_000_000,
                    UInt64(remaining * 1_000_000_000)
                )
            )
        }
        if process.isRunning {
            process.terminate()
            while process.isRunning {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 {
                    break
                }
                try await Task.sleep(
                    nanoseconds: min(
                        10_000_000,
                        UInt64(remaining * 1_000_000_000)
                    )
                )
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            throw ServiceManagerError.commandTimedOut(
                command: ([executableURL.lastPathComponent] + arguments)
                    .joined(separator: " ")
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return ServiceCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(
                decoding: stdoutData.prefix(outputLimit),
                as: UTF8.self
            ),
            stderr: String(
                decoding: stderrData.prefix(outputLimit),
                as: UTF8.self
            )
        )
    }
}

final class ServiceManager: ServiceManaging {
    static let label = "com.wuyi.mac-face-lock-background"
    static let legacyReleaseLabel = "com.wuyi.mac-face-lock-agent"
    static let productionHealthPollAttempts = 301
    static let productionHealthPollIntervalNanoseconds: UInt64 = 1_000_000_000
    static let productionStableHealthWindowSeconds: TimeInterval = 300

    private let appURL: URL
    private let supportURL: URL
    private let launchAgentsURL: URL
    private let templateURL: URL
    private let fileSystem: ServiceFileSystem
    private let commandRunner: ServiceCommandRunning
    private let userID: uid_t
    private let commandTimeout: TimeInterval
    private let healthPollAttempts: Int
    private let healthPollIntervalNanoseconds: UInt64
    private let stableHealthTimeout: TimeInterval
    private let heartbeatMaxAge: TimeInterval
    private let now: () -> Date
    private let monotonicNow: () -> TimeInterval
    private let sleep: (UInt64) async throws -> Void
    private let launchctlURL = URL(fileURLWithPath: "/bin/launchctl")

    init(
        appURL: URL,
        supportURL: URL,
        launchAgentsURL: URL? = nil,
        templateURL: URL? = nil,
        fileSystem: ServiceFileSystem = FoundationServiceFileSystem(),
        commandRunner: ServiceCommandRunning = BoundedServiceCommandRunner(),
        userID: uid_t = getuid(),
        commandTimeout: TimeInterval = 5,
        healthPollAttempts: Int = ServiceManager.productionHealthPollAttempts,
        healthPollIntervalNanoseconds: UInt64 =
            ServiceManager.productionHealthPollIntervalNanoseconds,
        stableHealthTimeout: TimeInterval =
            ServiceManager.productionStableHealthWindowSeconds,
        heartbeatMaxAge: TimeInterval = 15,
        now: @escaping () -> Date = Date.init,
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.appURL = appURL.standardizedFileURL
        self.supportURL = supportURL.standardizedFileURL
        self.launchAgentsURL = (
            launchAgentsURL
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        ).standardizedFileURL
        self.templateURL = (
            templateURL
                ?? appURL.appendingPathComponent(
                    "Contents/Resources/launchd/com.wuyi.mac-face-lock-release.plist"
                )
        ).standardizedFileURL
        self.fileSystem = fileSystem
        self.commandRunner = commandRunner
        self.userID = userID
        self.commandTimeout = commandTimeout
        self.healthPollAttempts = max(3, healthPollAttempts)
        self.healthPollIntervalNanoseconds = healthPollIntervalNanoseconds
        self.stableHealthTimeout = stableHealthTimeout.isFinite
            ? min(
                max(0, stableHealthTimeout),
                Self.productionStableHealthWindowSeconds
            )
            : Self.productionStableHealthWindowSeconds
        self.heartbeatMaxAge = max(0, heartbeatMaxAge)
        self.now = now
        self.monotonicNow = monotonicNow
        self.sleep = sleep
    }

    func install(appURL: URL, supportURL: URL) async throws {
        let normalizedAppURL = appURL.standardizedFileURL
        let normalizedSupportURL = supportURL.standardizedFileURL
        let dataDirectoryURL = normalizedSupportURL.appendingPathComponent(
            "data",
            isDirectory: true
        )
        let controlURL = dataDirectoryURL.appendingPathComponent("control.json")
        let createdDataDirectory: Bool
        if fileSystem.fileExists(at: controlURL) {
            createdDataDirectory = false
        } else {
            try fileSystem.createDirectory(at: dataDirectoryURL)
            createdDataDirectory = true
        }
        try writeProtectionDisabled(supportURL: normalizedSupportURL)

        let legacyData = fileSystem.fileExists(at: legacyPlistURL)
            ? try fileSystem.readData(at: legacyPlistURL)
            : nil
        if let legacyData,
           !Self.isRecognizedLegacyReleasePlist(
               legacyData,
               appURL: normalizedAppURL,
               supportURL: normalizedSupportURL
           ) {
            throw ServiceManagerError.invalidTemplate
        }
        let legacyWasLoaded = try await jobIsLoaded(target: legacyServiceTarget)
        if legacyWasLoaded && legacyData == nil {
            throw ServiceManagerError.invalidTemplate
        }
        let currentStatus = await status()
        if currentStatus.isResponsive {
            try await cleanupLegacyAfterResponsiveService(
                legacyData: legacyData,
                legacyWasLoaded: legacyWasLoaded
            )
            return
        }

        try fileSystem.createDirectory(at: launchAgentsURL)
        if !createdDataDirectory {
            try fileSystem.createDirectory(at: dataDirectoryURL)
        }
        try fileSystem.createDirectory(
            at: normalizedSupportURL.appendingPathComponent("logs", isDirectory: true)
        )

        let destinationURL = plistURL
        let backupURL = destinationURL.appendingPathExtension("backup")
        let previousData = fileSystem.fileExists(at: destinationURL)
            ? try fileSystem.readData(at: destinationURL)
            : nil
        let previousWasLoaded = try await jobIsLoaded(target: serviceTarget)
        let legacyBackupURL = legacyPlistURL.appendingPathExtension("backup")

        do {
            if let previousData {
                try fileSystem.writeAtomically(previousData, to: backupURL)
            }
            if let legacyData {
                try fileSystem.writeAtomically(legacyData, to: legacyBackupURL)
            }

            if legacyWasLoaded {
                try await stopJobAndWaitUntilAbsent(target: legacyServiceTarget)
            }
            if previousWasLoaded {
                try await stopJobAndWaitUntilAbsent(target: serviceTarget)
            } else {
                try await waitUntilJobAbsent(target: serviceTarget)
            }
            let templateData = try fileSystem.readData(at: templateURL)
            let renderedData = try Self.renderTemplate(
                templateData,
                appURL: normalizedAppURL,
                supportURL: normalizedSupportURL
            )
            try atomicReplace(renderedData, at: destinationURL)
            try await runRequiredLaunchctl(
                ["bootstrap", userDomain, destinationURL.path]
            )
            try await runRequiredLaunchctl(["enable", serviceTarget])
            try await requireStableResponsiveness()
            if fileSystem.fileExists(at: backupURL) {
                try fileSystem.removeItem(at: backupURL)
            }
            if legacyData != nil {
                try fileSystem.removeItem(at: legacyPlistURL)
            }
            if fileSystem.fileExists(at: legacyBackupURL) {
                try fileSystem.removeItem(at: legacyBackupURL)
            }
        } catch {
            do {
                try await rollback(
                    previousData: previousData,
                    previousWasLoaded: previousWasLoaded,
                    backupURL: backupURL,
                    legacyData: legacyData,
                    legacyWasLoaded: legacyWasLoaded,
                    legacyBackupURL: legacyBackupURL
                )
            } catch {
                throw ServiceManagerError.rollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }

    func status() async -> ServiceStatus {
        await status(commandTimeout: commandTimeout)
    }

    private func status(commandTimeout: TimeInterval) async -> ServiceStatus {
        let expectedArguments = expectedServiceArguments(
            appURL: appURL,
            supportURL: supportURL
        )
        let expectedProgram = expectedArguments[0]
        guard fileSystem.fileExists(at: plistURL) else {
            return ServiceStatus(
                state: .notInstalled,
                pid: nil,
                cameraReady: false,
                inputMonitoringReady: false,
                accessibilityReady: false,
                installedProgram: nil,
                expectedProgram: expectedProgram
            )
        }
        guard let configuration = installedServiceConfiguration() else {
            return ServiceStatus(
                state: .needsRepair,
                pid: nil,
                cameraReady: false,
                inputMonitoringReady: false,
                accessibilityReady: false,
                installedProgram: nil,
                expectedProgram: expectedProgram
            )
        }
        let installedProgram = configuration.arguments.first
        guard let templateData = try? fileSystem.readData(at: templateURL),
              let renderedTemplate = try? Self.renderTemplate(
                  templateData,
                  appURL: appURL,
                  supportURL: supportURL
              ),
              let expectedDictionary = Self.plistDictionary(
                  from: renderedTemplate
              ),
              Self.propertyListValuesExactlyEqual(
                  configuration.dictionary,
                  expectedDictionary
              ),
              let installedProgram else {
            return ServiceStatus(
                state: .needsRepair,
                pid: nil,
                cameraReady: false,
                inputMonitoringReady: false,
                accessibilityReady: false,
                installedProgram: installedProgram,
                expectedProgram: expectedProgram
            )
        }

        guard let result = try? await runLaunchctl(
            ["print", serviceTarget],
            timeout: commandTimeout
        ),
              result.exitCode == 0,
              let pid = Self.parsePID(result.stdout),
              pid > 0 else {
            return unhealthyStatus(
                pid: nil,
                installedProgram: installedProgram,
                state: nil
            )
        }
        let state = readAgentState()
        let cameraReady = state?.cameraReady == true
        let inputMonitoringReady = state?.inputMonitoringReady == true
        let accessibilityReady = state?.accessibilityReady == true
        let heartbeatTimestamp = state?.heartbeatTimestamp
        let heartbeatSequence = state?.heartbeatSequence
        let heartbeatFresh = heartbeatTimestamp.flatMap {
            ISO8601DateFormatter().date(from: $0)
        }.map {
            let age = now().timeIntervalSince($0)
            return age >= 0 && age <= heartbeatMaxAge
        } == true
        let runningState = state.map {
            !["missing", "stopped", "input_listener_error"].contains($0.status)
        } == true
        let responsive = state?.agentPid == pid
            && heartbeatSequence != nil
            && heartbeatFresh
            && runningState
        let healthy = responsive
            && cameraReady
            && inputMonitoringReady
            && accessibilityReady
        return ServiceStatus(
            state: healthy ? .healthy : .unhealthy,
            pid: pid,
            cameraReady: cameraReady,
            inputMonitoringReady: inputMonitoringReady,
            accessibilityReady: accessibilityReady,
            installedProgram: installedProgram,
            expectedProgram: expectedProgram,
            heartbeatTimestamp: heartbeatTimestamp,
            heartbeatSequence: heartbeatSequence,
            isResponsive: responsive
        )
    }

    func restart() async throws {
        try await runRequiredLaunchctl(["enable", serviceTarget])
        try await runRequiredLaunchctl(["kickstart", "-k", serviceTarget])
    }

    func uninstallPreservingData() async throws -> ServiceStatus {
        try await stopJobAndWaitUntilAbsent(target: serviceTarget)
        if fileSystem.fileExists(at: plistURL) {
            try fileSystem.removeItem(at: plistURL)
        }
        return ServiceStatus(
            state: .notInstalled,
            pid: nil,
            cameraReady: false,
            inputMonitoringReady: false,
            accessibilityReady: false,
            installedProgram: nil,
            expectedProgram: expectedServiceArguments(
                appURL: appURL,
                supportURL: supportURL
            )[0]
        )
    }

    private var plistURL: URL {
        launchAgentsURL.appendingPathComponent("\(Self.label).plist")
    }

    private var userDomain: String {
        "gui/\(userID)"
    }

    private var serviceTarget: String {
        "\(userDomain)/\(Self.label)"
    }

    private var legacyPlistURL: URL {
        launchAgentsURL.appendingPathComponent(
            "\(Self.legacyReleaseLabel).plist"
        )
    }

    private var legacyServiceTarget: String {
        "\(userDomain)/\(Self.legacyReleaseLabel)"
    }

    private var stateURL: URL {
        supportURL.appendingPathComponent("data/state.json")
    }

    private func expectedServiceArguments(
        appURL: URL,
        supportURL: URL
    ) -> [String] {
        [
            appURL.appendingPathComponent("Contents/MacOS/MacFaceLock").path,
            "--internal-runtime",
            "--resources-dir",
            appURL.appendingPathComponent("Contents/Resources").path,
            "--support-dir",
            supportURL.path,
            "agent",
        ]
    }

    private func installedServiceConfiguration() -> (
        dictionary: [String: Any],
        arguments: [String]
    )? {
        guard let data = try? fileSystem.readData(at: plistURL),
              let dictionary = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let arguments = Self.plistArguments(in: dictionary) else {
            return nil
        }
        return (dictionary, arguments)
    }

    private func readAgentState() -> FaceLockState? {
        guard let data = try? fileSystem.readData(at: stateURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(FaceLockState.self, from: data)
    }

    private func unhealthyStatus(
        pid: Int32?,
        installedProgram: String,
        state: FaceLockState?
    ) -> ServiceStatus {
        ServiceStatus(
            state: .unhealthy,
            pid: pid,
            cameraReady: state?.cameraReady == true,
            inputMonitoringReady: state?.inputMonitoringReady == true,
            accessibilityReady: state?.accessibilityReady == true,
            installedProgram: installedProgram,
            expectedProgram: expectedServiceArguments(
                appURL: appURL,
                supportURL: supportURL
            )[0],
            heartbeatTimestamp: state?.heartbeatTimestamp,
            heartbeatSequence: state?.heartbeatSequence
        )
    }

    private func writeProtectionDisabled(supportURL: URL) throws {
        let controlURL = supportURL.appendingPathComponent("data/control.json")
        let object: [String: Any] = [
            "schema_version": 1,
            "protection_enabled": false,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try fileSystem.writeAtomically(data, to: controlURL)
    }

    private func requireStableResponsiveness() async throws {
        let deadline = monotonicNow() + stableHealthTimeout
        var stablePID: Int32?
        var stableHeartbeatSequence: UInt64?
        var consecutiveResponsivePolls = 0
        for attempt in 0..<healthPollAttempts {
            let remainingBeforeProbe = deadline - monotonicNow()
            guard remainingBeforeProbe > 0 else {
                break
            }
            let current = await status(
                commandTimeout: min(commandTimeout, remainingBeforeProbe)
            )
            if current.isResponsive,
               let pid = current.pid,
               pid > 0,
               let sequence = current.heartbeatSequence {
                if stablePID == pid {
                    if let previousSequence = stableHeartbeatSequence,
                       sequence > previousSequence {
                        consecutiveResponsivePolls += 1
                        stableHeartbeatSequence = sequence
                    } else if let previousSequence = stableHeartbeatSequence,
                              sequence < previousSequence {
                        consecutiveResponsivePolls = 1
                        stableHeartbeatSequence = sequence
                    } else {
                        // A faster status poll may observe the same live heartbeat.
                        // Keep waiting without treating it as progression.
                    }
                } else {
                    stablePID = pid
                    consecutiveResponsivePolls = 1
                    stableHeartbeatSequence = sequence
                }
                if consecutiveResponsivePolls == 3 {
                    return
                }
            } else {
                stablePID = nil
                stableHeartbeatSequence = nil
                consecutiveResponsivePolls = 0
            }
            let remainingAfterProbe = deadline - monotonicNow()
            guard remainingAfterProbe > 0 else {
                break
            }
            if attempt + 1 < healthPollAttempts,
               healthPollIntervalNanoseconds > 0 {
                let remainingNanoseconds = UInt64(
                    remainingAfterProbe * 1_000_000_000
                )
                let sleepNanoseconds = min(
                    healthPollIntervalNanoseconds,
                    remainingNanoseconds
                )
                if sleepNanoseconds > 0 {
                    try await sleep(sleepNanoseconds)
                }
            }
        }
        throw ServiceManagerError.unstableService
    }

    private func rollback(
        previousData: Data?,
        previousWasLoaded: Bool,
        backupURL: URL,
        legacyData: Data?,
        legacyWasLoaded: Bool,
        legacyBackupURL: URL
    ) async throws {
        try await stopJobAndWaitUntilAbsent(target: serviceTarget)
        if let previousData {
            try atomicReplace(previousData, at: plistURL)
            if previousWasLoaded {
                try await runRequiredLaunchctl(
                    ["bootstrap", userDomain, plistURL.path]
                )
                try await runRequiredLaunchctl(["enable", serviceTarget])
            }
        } else if fileSystem.fileExists(at: plistURL) {
            try fileSystem.removeItem(at: plistURL)
        }
        if fileSystem.fileExists(at: backupURL) {
            try fileSystem.removeItem(at: backupURL)
        }
        if let legacyData {
            try atomicReplace(legacyData, at: legacyPlistURL)
            if legacyWasLoaded,
               try await !jobIsLoaded(target: legacyServiceTarget) {
                try await runRequiredLaunchctl(
                    ["bootstrap", userDomain, legacyPlistURL.path]
                )
                try await runRequiredLaunchctl(["enable", legacyServiceTarget])
            }
        }
        if fileSystem.fileExists(at: legacyBackupURL) {
            try fileSystem.removeItem(at: legacyBackupURL)
        }
    }

    private func cleanupLegacyAfterResponsiveService(
        legacyData: Data?,
        legacyWasLoaded: Bool
    ) async throws {
        guard let legacyData else {
            return
        }
        let backupURL = legacyPlistURL.appendingPathExtension("backup")
        do {
            try fileSystem.writeAtomically(legacyData, to: backupURL)
            if legacyWasLoaded {
                try await stopJobAndWaitUntilAbsent(
                    target: legacyServiceTarget
                )
            }
            try fileSystem.removeItem(at: legacyPlistURL)
            if fileSystem.fileExists(at: backupURL) {
                try fileSystem.removeItem(at: backupURL)
            }
        } catch {
            do {
                try atomicReplace(legacyData, at: legacyPlistURL)
                if legacyWasLoaded,
                   try await !jobIsLoaded(target: legacyServiceTarget) {
                    try await runRequiredLaunchctl(
                        ["bootstrap", userDomain, legacyPlistURL.path]
                    )
                    try await runRequiredLaunchctl(
                        ["enable", legacyServiceTarget]
                    )
                }
                if fileSystem.fileExists(at: backupURL) {
                    try fileSystem.removeItem(at: backupURL)
                }
            } catch {
                throw ServiceManagerError.rollbackFailed(
                    error.localizedDescription
                )
            }
            throw error
        }
    }

    private func atomicReplace(_ data: Data, at destinationURL: URL) throws {
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
            )
        try fileSystem.writeAtomically(data, to: temporaryURL)
        try fileSystem.replaceItem(
            at: destinationURL,
            withItemAt: temporaryURL
        )
    }

    private func jobIsLoaded(target: String) async throws -> Bool {
        let result = try await runLaunchctl(["print", target])
        return try jobIsLoaded(from: result, target: target)
    }

    private func jobIsLoaded(
        from result: ServiceCommandResult,
        target: String
    ) throws -> Bool {
        if result.exitCode == 0 {
            return true
        }
        if result.exitCode == 113 {
            return false
        }
        throw ServiceManagerError.commandFailed(
            command: "launchctl print \(target)",
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }

    private func stopJobAndWaitUntilAbsent(target: String) async throws {
        let bootoutResult = try await runLaunchctl(["bootout", target])
        if bootoutResult.exitCode != 0 {
            let printResult = try await runLaunchctl(["print", target])
            guard try !jobIsLoaded(from: printResult, target: target) else {
                throw ServiceManagerError.commandFailed(
                    command: "launchctl bootout \(target)",
                    exitCode: bootoutResult.exitCode,
                    stderr: bootoutResult.stderr
                )
            }
            return
        }
        try await waitUntilJobAbsent(target: target)
    }

    private func waitUntilJobAbsent(target: String) async throws {
        let attempts = min(healthPollAttempts, 20)
        for attempt in 0..<attempts {
            if try await !jobIsLoaded(target: target) {
                return
            }
            if attempt + 1 < attempts,
               healthPollIntervalNanoseconds > 0 {
                try await sleep(healthPollIntervalNanoseconds)
            }
        }
        throw ServiceManagerError.unstableService
    }

    private func runLaunchctl(
        _ arguments: [String],
        timeout: TimeInterval? = nil
    ) async throws -> ServiceCommandResult {
        try await commandRunner.run(
            executableURL: launchctlURL,
            arguments: arguments,
            timeout: timeout ?? commandTimeout
        )
    }

    private func runRequiredLaunchctl(_ arguments: [String]) async throws {
        let result = try await runLaunchctl(arguments)
        guard result.exitCode == 0 else {
            throw ServiceManagerError.commandFailed(
                command: (["launchctl"] + arguments).joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    private static func renderTemplate(
        _ data: Data,
        appURL: URL,
        supportURL: URL
    ) throws -> Data {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw ServiceManagerError.invalidTemplate
        }

        func replaceTokens(_ value: Any) -> Any {
            if let string = value as? String {
                return string
                    .replacingOccurrences(of: "__APP_URL__", with: appURL.path)
                    .replacingOccurrences(of: "__SUPPORT_URL__", with: supportURL.path)
            }
            if let array = value as? [Any] {
                return array.map(replaceTokens)
            }
            if let dictionary = value as? [String: Any] {
                return dictionary.mapValues(replaceTokens)
            }
            return value
        }

        do {
            return try PropertyListSerialization.data(
                fromPropertyList: replaceTokens(object),
                format: .xml,
                options: 0
            )
        } catch {
            throw ServiceManagerError.invalidTemplate
        }
    }

    private static func isRecognizedLegacyReleasePlist(
        _ data: Data,
        appURL: URL,
        supportURL: URL
    ) -> Bool {
        guard let dictionary = plistDictionary(from: data) else {
            return false
        }
        guard plistArguments(in: dictionary) != nil else {
            return false
        }
        var expected: [String: Any] = [
            "Label": legacyReleaseLabel,
            "WorkingDirectory": supportURL.path,
            "StandardOutPath": supportURL
                .appendingPathComponent("logs/agent-launchd.log").path,
            "StandardErrorPath": supportURL
                .appendingPathComponent("logs/agent-launchd.error.log").path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
        ]
        let argumentKeys = Set(dictionary.keys).subtracting(expected.keys)
        guard argumentKeys.count == 1, let argumentKey = argumentKeys.first else {
            return false
        }
        expected[argumentKey] = [
            appURL.appendingPathComponent(
                "Contents/Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
            ).path,
            "--resources-dir",
            appURL.appendingPathComponent("Contents/Resources").path,
            "--support-dir",
            supportURL.path,
            "agent",
        ]
        return propertyListValuesExactlyEqual(dictionary, expected)
    }

    private static func plistArguments(
        in dictionary: [String: Any]
    ) -> [String]? {
        let arguments = dictionary["ProgramArguments"] as? [String]
        return arguments
    }

    private static func plistDictionary(
        from data: Data
    ) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private static func propertyListValuesExactlyEqual(
        _ lhs: Any,
        _ rhs: Any
    ) -> Bool {
        if let lhs = lhs as? [String: Any] {
            guard let rhs = rhs as? [String: Any],
                  lhs.keys == rhs.keys else {
                return false
            }
            return lhs.allSatisfy { key, value in
                guard let rhsValue = rhs[key] else {
                    return false
                }
                return propertyListValuesExactlyEqual(value, rhsValue)
            }
        }
        if let lhs = lhs as? [Any] {
            guard let rhs = rhs as? [Any],
                  lhs.count == rhs.count else {
                return false
            }
            return zip(lhs, rhs).allSatisfy {
                propertyListValuesExactlyEqual($0, $1)
            }
        }
        if let lhs = lhs as? String {
            guard let rhs = rhs as? String else {
                return false
            }
            return lhs == rhs
        }
        if let lhs = lhs as? NSNumber {
            guard let rhs = rhs as? NSNumber else {
                return false
            }
            let lhsIsBoolean = CFGetTypeID(lhs) == CFBooleanGetTypeID()
            let rhsIsBoolean = CFGetTypeID(rhs) == CFBooleanGetTypeID()
            guard lhsIsBoolean == rhsIsBoolean else {
                return false
            }
            return lhsIsBoolean
                ? lhs.boolValue == rhs.boolValue
                : lhs == rhs
        }
        if let lhs = lhs as? Data {
            guard let rhs = rhs as? Data else {
                return false
            }
            return lhs == rhs
        }
        if let lhs = lhs as? Date {
            guard let rhs = rhs as? Date else {
                return false
            }
            return lhs == rhs
        }
        return false
    }

    private static func parsePID(_ output: String) -> Int32? {
        let pattern = #"(?m)^\s*pid\s*=\s*([0-9]+)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return Int32(output[range])
    }
}
