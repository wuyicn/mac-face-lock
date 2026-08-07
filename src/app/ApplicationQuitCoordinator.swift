enum ApplicationTerminationDecision: Equatable {
    case terminateCancel
    case terminateLater
    case terminateNow
}

@MainActor
final class ApplicationQuitCoordinator {
    private enum TerminationState {
        case idle
        case confirming
        case stopping
        case approved
    }

    private let stopBackground: () async -> Bool
    private let terminate: () -> Void
    private let cancelTermination: () -> Void
    private let cancelDeferredTermination: () -> Void
    private var nextRequestID: UInt64 = 0
    private var activeRequest: (id: UInt64, task: Task<Bool, Never>)?
    private var terminationState: TerminationState = .idle
    private var hasDeferredConfirmationRequest = false

    init(
        stopBackground: @escaping () async -> Bool,
        terminate: @escaping () -> Void,
        cancelTermination: @escaping () -> Void = {},
        cancelDeferredTermination: @escaping () -> Void = {}
    ) {
        self.stopBackground = stopBackground
        self.terminate = terminate
        self.cancelTermination = cancelTermination
        self.cancelDeferredTermination = cancelDeferredTermination
    }

    func applicationShouldTerminate(
        confirm: () -> Bool
    ) -> ApplicationTerminationDecision {
        switch terminationState {
        case .approved:
            return .terminateNow
        case .confirming:
            hasDeferredConfirmationRequest = true
            return .terminateLater
        case .stopping:
            return .terminateLater
        case .idle:
            terminationState = .confirming
            hasDeferredConfirmationRequest = false
            guard confirm() else {
                terminationState = .idle
                if hasDeferredConfirmationRequest {
                    hasDeferredConfirmationRequest = false
                    cancelDeferredTermination()
                }
                return .terminateCancel
            }
            terminationState = .stopping
            hasDeferredConfirmationRequest = false
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let stopped = await self.requestQuit()
                guard !stopped else {
                    return
                }
                self.terminationState = .idle
                self.cancelTermination()
            }
            return .terminateLater
        }
    }

    func requestQuit() async -> Bool {
        if let activeRequest {
            return await activeRequest.task.value
        }

        nextRequestID &+= 1
        let requestID = nextRequestID
        let stopBackground = self.stopBackground
        let terminate = self.terminate
        let task = Task { @MainActor in
            let stopped = await stopBackground()
            if stopped {
                if self.terminationState == .stopping {
                    self.terminationState = .approved
                }
                terminate()
            }
            return stopped
        }
        activeRequest = (requestID, task)

        let result = await task.value
        if activeRequest?.id == requestID {
            activeRequest = nil
        }
        return result
    }
}
