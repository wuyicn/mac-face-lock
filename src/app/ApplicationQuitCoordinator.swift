enum ApplicationTerminationDecision: Equatable {
    case terminateCancel
    case terminateLater
    case terminateNow
}

@MainActor
final class ApplicationQuitCoordinator {
    private enum TerminationState {
        case idle
        case stopping
        case approved
    }

    private let stopBackground: () async -> Bool
    private let terminate: () -> Void
    private let cancelTermination: () -> Void
    private var nextRequestID: UInt64 = 0
    private var activeRequest: (id: UInt64, task: Task<Bool, Never>)?
    private var terminationState: TerminationState = .idle

    init(
        stopBackground: @escaping () async -> Bool,
        terminate: @escaping () -> Void,
        cancelTermination: @escaping () -> Void = {}
    ) {
        self.stopBackground = stopBackground
        self.terminate = terminate
        self.cancelTermination = cancelTermination
    }

    func applicationShouldTerminate(
        confirm: () -> Bool
    ) -> ApplicationTerminationDecision {
        switch terminationState {
        case .approved:
            return .terminateNow
        case .stopping:
            return .terminateLater
        case .idle:
            guard confirm() else {
                return .terminateCancel
            }
            terminationState = .stopping
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
