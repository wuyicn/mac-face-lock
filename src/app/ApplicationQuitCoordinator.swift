@MainActor
final class ApplicationQuitCoordinator {
    private let stopBackground: () async -> Bool
    private let terminate: () -> Void
    private var nextRequestID: UInt64 = 0
    private var activeRequest: (id: UInt64, task: Task<Bool, Never>)?

    init(
        stopBackground: @escaping () async -> Bool,
        terminate: @escaping () -> Void
    ) {
        self.stopBackground = stopBackground
        self.terminate = terminate
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
