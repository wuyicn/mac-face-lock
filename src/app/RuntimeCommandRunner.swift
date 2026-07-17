import Darwin
import Foundation

enum RuntimeCommand: String, CaseIterable, Hashable {
    case agent
    case enroll
    case diagnose
    case verifyOwner = "verify-owner"

    fileprivate var allowedEvents: Set<String> {
        let failures = ["camera_unavailable", "runtime_failure"]
        switch self {
        case .agent:
            return Set(["agent_started", "agent_stopped"] + failures)
        case .enroll:
            return Set(
                ["enrollment_started", "enrollment_progress", "enrollment_complete"] + failures
            )
        case .diagnose:
            return Set(["diagnosis_check", "diagnosis_complete"] + failures)
        case .verifyOwner:
            return Set(
                ["owner_verification_complete", "owner_profile_invalid"] + failures
            )
        }
    }

    fileprivate var terminalEvents: Set<String> {
        let failures = ["camera_unavailable", "runtime_failure"]
        switch self {
        case .agent:
            return Set(["agent_stopped"] + failures)
        case .enroll:
            return Set(["enrollment_complete"] + failures)
        case .diagnose:
            return Set(["diagnosis_complete"] + failures)
        case .verifyOwner:
            return Set(
                ["owner_verification_complete", "owner_profile_invalid"] + failures
            )
        }
    }
}

struct RuntimeEvent: Decodable, Equatable {
    let schemaVersion: Int
    let event: String
    let status: String
    let message: String
    let capturedSamples: Int?
    let requiredSamples: Int?
    let check: String?
    let failedChecks: [String]?
    let decision: String?
    let failureKind: String?

    init(
        schemaVersion: Int,
        event: String,
        status: String,
        message: String,
        capturedSamples: Int? = nil,
        requiredSamples: Int? = nil,
        check: String? = nil,
        failedChecks: [String]? = nil,
        decision: String? = nil,
        failureKind: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.event = event
        self.status = status
        self.message = message
        self.capturedSamples = capturedSamples
        self.requiredSamples = requiredSamples
        self.check = check
        self.failedChecks = failedChecks
        self.decision = decision
        self.failureKind = failureKind
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case event
        case status
        case message
        case capturedSamples = "captured_samples"
        case requiredSamples = "required_samples"
        case check
        case failedChecks = "failed_checks"
        case decision
        case failureKind = "failure_kind"
    }
}

struct RuntimeResult: Equatable {
    let exitCode: Int32
    let events: [RuntimeEvent]
    let stderr: String
    let stderrTruncated: Bool
}

enum RuntimeTerminalCompatibility {
    static func accepts(
        command: RuntimeCommand,
        terminalEvent: RuntimeEvent,
        events: [RuntimeEvent],
        exitCode: Int32
    ) -> Bool {
        switch command {
        case .agent:
            switch (terminalEvent.event, terminalEvent.status, exitCode) {
            case ("agent_stopped", "success", 0),
                 ("camera_unavailable", "error", 10),
                 ("runtime_failure", "error", 20):
                return true
            default:
                return false
            }
        case .enroll:
            switch (terminalEvent.event, terminalEvent.status, exitCode) {
            case ("enrollment_complete", "success", 0),
                 ("camera_unavailable", "error", 10),
                 ("runtime_failure", "error", 20):
                return true
            default:
                return false
            }
        case .diagnose:
            switch (terminalEvent.event, terminalEvent.status, exitCode) {
            case ("camera_unavailable", "error", 10),
                 ("runtime_failure", "error", 20),
                 ("diagnosis_complete", "success", 0):
                return true
            case ("diagnosis_complete", "error", _):
                return exitCode == diagnosisFailureExitCode(
                    terminalEvent: terminalEvent,
                    events: events
                )
            default:
                return false
            }
        case .verifyOwner:
            switch (terminalEvent.event, terminalEvent.status, exitCode) {
            case ("owner_verification_complete", "success", 0),
                 ("owner_profile_invalid", "error", 11),
                 ("owner_verification_complete", "error", 12),
                 ("camera_unavailable", "error", 10),
                 ("runtime_failure", "error", 20):
                return true
            default:
                return false
            }
        }
    }

    private static func diagnosisFailureExitCode(
        terminalEvent: RuntimeEvent,
        events: [RuntimeEvent]
    ) -> Int32? {
        let failedChecks = Set(terminalEvent.failedChecks ?? [])
        guard !failedChecks.isEmpty else {
            return nil
        }
        let hasRuntimeFailure = events.contains {
            $0.event == "diagnosis_check"
                && $0.status != "success"
                && $0.failureKind == "runtime"
        }
        if hasRuntimeFailure {
            return 20
        }
        if failedChecks.contains("camera") {
            return 10
        }
        if failedChecks.contains("template") {
            return 11
        }
        return 20
    }
}

enum RuntimeCommandRunnerError: Error, Equatable, LocalizedError {
    case launchFailed
    case malformedEvent
    case outputLineTooLong
    case eventBudgetExceeded
    case unsupportedSchemaVersion(Int)
    case unexpectedEvent(String)
    case duplicateTerminalEvent
    case missingTerminalEvent
    case inconsistentSuccessfulExit

    var errorDescription: String? {
        switch self {
        case .launchFailed:
            return "无法启动内置运行组件，请重新安装应用后再试。"
        case .malformedEvent:
            return "无法解析运行组件返回的进度，请重新运行诊断。"
        case .outputLineTooLong:
            return "运行组件返回的数据过长，已安全停止；请重新运行诊断。"
        case .eventBudgetExceeded:
            return "运行组件返回的事件数量过多，已安全停止；请重新运行诊断。"
        case .unsupportedSchemaVersion:
            return "运行组件版本与应用不兼容，请更新或重新安装应用。"
        case .unexpectedEvent, .duplicateTerminalEvent, .missingTerminalEvent,
             .inconsistentSuccessfulExit:
            return "运行组件返回了不受支持的结果，请更新或重新安装应用。"
        }
    }
}

protocol RuntimeCommandRunning: AnyObject {
    func run(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult
}

final class RuntimeCommandRunner: RuntimeCommandRunning {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func run(
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) async throws -> RuntimeResult {
        let process = Process()
        process.executableURL = environment.runtimeExecutableURL
        process.arguments = arguments(for: command)
        let session = RuntimeProcessSession(
            process: process,
            command: command,
            onEvent: onEvent
        )
        return try await session.run()
    }

    private func arguments(for command: RuntimeCommand) -> [String] {
        var arguments: [String] = []
        if environment.mode == .source {
            arguments.append(
                environment.resourcesURL.appendingPathComponent("runtime_cli.py").path
            )
        }
        arguments.append(contentsOf: [
            "--resources-dir",
            environment.resourcesURL.path,
            "--support-dir",
            environment.supportURL.path,
            command.rawValue,
        ])
        return arguments
    }
}

private final class RuntimeProcessSession {
    private struct Completion {
        let continuation: CheckedContinuation<RuntimeResult, Error>
        let result: Result<RuntimeResult, Error>
    }

    private static let maximumLineBytes = 256 * 1_024
    private static let maximumStderrBytes = 1 * 1_024 * 1_024
    private static let maximumRetainedEventCount = 1_024
    private static let maximumRetainedEventBytes = 2 * 1_024 * 1_024

    private let process: Process
    private let command: RuntimeCommand
    private let onEvent: (RuntimeEvent) -> Void
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let decoder: JSONDecoder
    private let lock = NSLock()

    private var continuation: CheckedContinuation<RuntimeResult, Error>?
    private var stdoutBuffer = Data()
    private var retainedStderr = Data()
    private var stderrTruncated = false
    private var events: [RuntimeEvent] = []
    private var retainedEventBytes = 0
    private var terminalEvent: RuntimeEvent?
    private var terminalError: Error?
    private var exitCode: Int32?
    private var stdoutReachedEOF = false
    private var stderrReachedEOF = false
    private var cancellationRequested = false
    private var didComplete = false

    init(
        process: Process,
        command: RuntimeCommand,
        onEvent: @escaping (RuntimeEvent) -> Void
    ) {
        self.process = process
        self.command = command
        self.onEvent = onEvent
        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    func run() async throws -> RuntimeResult {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    begin(continuation: continuation)
                }
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )
    }

    private func begin(
        continuation: CheckedContinuation<RuntimeResult, Error>
    ) {
        lock.lock()
        self.continuation = continuation
        let shouldCancel = cancellationRequested || Task.isCancelled
        lock.unlock()

        guard !shouldCancel else {
            completeImmediately(with: CancellationError())
            return
        }

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveStderr(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.receiveTermination(exitCode: process.terminationStatus)
        }

        lock.lock()
        let cancelledBeforeLaunch = cancellationRequested || Task.isCancelled
        lock.unlock()
        guard !cancelledBeforeLaunch else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            completeImmediately(with: CancellationError())
            return
        }
        do {
            try process.run()
            lock.lock()
            let cancelledDuringLaunch = cancellationRequested
            lock.unlock()
            if cancelledDuringLaunch {
                terminateProcess()
            }
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            completeImmediately(with: RuntimeCommandRunnerError.launchFailed)
        }
    }

    private func receiveStdout(_ data: Data) {
        var deliveredEvents: [RuntimeEvent] = []
        var shouldTerminate = false

        lock.lock()
        if data.isEmpty {
            if terminalError == nil, !stdoutBuffer.isEmpty {
                if stdoutBuffer.count > Self.maximumLineBytes {
                    terminalError = RuntimeCommandRunnerError.outputLineTooLong
                } else {
                    decodeLine(stdoutBuffer, deliveredEvents: &deliveredEvents)
                }
                stdoutBuffer.removeAll(keepingCapacity: false)
            }
            stdoutReachedEOF = true
        } else if terminalError == nil {
            appendStdout(data, deliveredEvents: &deliveredEvents)
        }
        shouldTerminate = terminalError != nil && process.isRunning
        let completion = takeCompletionIfReady()
        lock.unlock()

        for event in deliveredEvents {
            onEvent(event)
        }
        if shouldTerminate {
            terminateProcess()
        }
        resume(completion)
    }

    private func appendStdout(
        _ data: Data,
        deliveredEvents: inout [RuntimeEvent]
    ) {
        var remaining = data[...]
        while let newline = remaining.firstIndex(of: 0x0A) {
            let fragment = remaining[..<newline]
            guard stdoutBuffer.count + fragment.count <= Self.maximumLineBytes else {
                terminalError = RuntimeCommandRunnerError.outputLineTooLong
                return
            }
            stdoutBuffer.append(contentsOf: fragment)
            if stdoutBuffer.last == 0x0D {
                stdoutBuffer.removeLast()
            }
            decodeLine(stdoutBuffer, deliveredEvents: &deliveredEvents)
            stdoutBuffer.removeAll(keepingCapacity: true)
            guard terminalError == nil else {
                return
            }
            remaining = remaining[remaining.index(after: newline)...]
        }

        guard stdoutBuffer.count + remaining.count <= Self.maximumLineBytes else {
            terminalError = RuntimeCommandRunnerError.outputLineTooLong
            return
        }
        stdoutBuffer.append(contentsOf: remaining)
    }

    private func decodeLine(
        _ line: Data,
        deliveredEvents: inout [RuntimeEvent]
    ) {
        guard !line.isEmpty,
              let event = try? decoder.decode(RuntimeEvent.self, from: line) else {
            terminalError = RuntimeCommandRunnerError.malformedEvent
            return
        }
        guard event.schemaVersion == 1 else {
            terminalError = RuntimeCommandRunnerError.unsupportedSchemaVersion(
                event.schemaVersion
            )
            return
        }
        guard command.allowedEvents.contains(event.event) else {
            terminalError = RuntimeCommandRunnerError.unexpectedEvent(event.event)
            return
        }
        guard events.count < Self.maximumRetainedEventCount,
              retainedEventBytes <= Self.maximumRetainedEventBytes - line.count else {
            terminalError = RuntimeCommandRunnerError.eventBudgetExceeded
            return
        }
        if command.terminalEvents.contains(event.event) {
            guard terminalEvent == nil else {
                terminalError = RuntimeCommandRunnerError.duplicateTerminalEvent
                return
            }
            terminalEvent = event
        } else if terminalEvent != nil {
            terminalError = RuntimeCommandRunnerError.unexpectedEvent(event.event)
            return
        }
        events.append(event)
        retainedEventBytes += line.count
        deliveredEvents.append(event)
    }

    private func receiveStderr(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            stderrReachedEOF = true
        } else {
            let remainingCapacity = max(
                Self.maximumStderrBytes - retainedStderr.count,
                0
            )
            if remainingCapacity > 0 {
                retainedStderr.append(data.prefix(remainingCapacity))
            }
            if data.count > remainingCapacity {
                stderrTruncated = true
            }
        }
        let completion = takeCompletionIfReady()
        lock.unlock()
        resume(completion)
    }

    private func receiveTermination(exitCode: Int32) {
        lock.lock()
        self.exitCode = exitCode
        let completion = takeCompletionIfReady()
        lock.unlock()
        resume(completion)
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let running = process.isRunning
        let completion = takeCompletionIfReady()
        lock.unlock()

        if running {
            terminateProcess()
        }
        resume(completion)
    }

    private func terminateProcess() {
        if process.isRunning {
            process.terminate()
        }
        let pid = process.processIdentifier
        guard pid > 0 else {
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak process] in
            guard let process, process.isRunning else {
                return
            }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private func takeCompletionIfReady() -> Completion? {
        guard !didComplete,
              let activeContinuation = continuation,
              let exitCode,
              stdoutReachedEOF,
              stderrReachedEOF else {
            return nil
        }
        self.continuation = nil
        didComplete = true

        if cancellationRequested {
            return Completion(
                continuation: activeContinuation,
                result: .failure(CancellationError())
            )
        }
        if let terminalError {
            return Completion(
                continuation: activeContinuation,
                result: .failure(terminalError)
            )
        }
        guard let terminalEvent else {
            return Completion(
                continuation: activeContinuation,
                result: .failure(RuntimeCommandRunnerError.missingTerminalEvent)
            )
        }
        guard RuntimeTerminalCompatibility.accepts(
            command: command,
            terminalEvent: terminalEvent,
            events: events,
            exitCode: exitCode
        ) else {
            return Completion(
                continuation: activeContinuation,
                result: .failure(RuntimeCommandRunnerError.inconsistentSuccessfulExit)
            )
        }
        return Completion(
            continuation: activeContinuation,
            result: .success(
                RuntimeResult(
                    exitCode: exitCode,
                    events: events,
                    stderr: String(decoding: retainedStderr, as: UTF8.self),
                    stderrTruncated: stderrTruncated
                )
            )
        )
    }

    private func completeImmediately(with error: Error) {
        lock.lock()
        guard !didComplete, let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        didComplete = true
        lock.unlock()
        continuation.resume(throwing: error)
    }

    private func resume(_ completion: Completion?) {
        guard let completion else {
            return
        }
        switch completion.result {
        case .success(let result):
            completion.continuation.resume(returning: result)
        case .failure(let error):
            completion.continuation.resume(throwing: error)
        }
    }
}
