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

@main
@MainActor
struct ApplicationQuitCoordinatorTests {
    static func main() async throws {
        try await testSuccessfulStopTerminatesInOrder()
        try await testFailedStopKeepsApplicationAlive()
        try await testConcurrentRequestsShareOneStop()
        try await testCancellationCannotTerminateBeforeStopSucceeds()
        print("Application quit coordinator tests passed")
    }

    private static func testSuccessfulStopTerminatesInOrder() async throws {
        var calls: [String] = []
        let subject = ApplicationQuitCoordinator(
            stopBackground: {
                calls.append("stop")
                return true
            },
            terminate: { calls.append("terminate") }
        )

        let result = await subject.requestQuit()

        try require(result, "successful stop did not permit termination")
        try require(
            calls == ["stop", "terminate"],
            "termination did not follow a successful stop: \(calls)"
        )
    }

    private static func testFailedStopKeepsApplicationAlive() async throws {
        var calls: [String] = []
        let subject = ApplicationQuitCoordinator(
            stopBackground: {
                calls.append("stop")
                return false
            },
            terminate: { calls.append("terminate") }
        )

        let result = await subject.requestQuit()

        try require(!result, "failed stop incorrectly permitted termination")
        try require(calls == ["stop"], "failed stop still terminated: \(calls)")
    }

    private static func testConcurrentRequestsShareOneStop() async throws {
        var calls: [String] = []
        var stopContinuation: CheckedContinuation<Bool, Never>?
        let subject = ApplicationQuitCoordinator(
            stopBackground: {
                calls.append("stop")
                return await withCheckedContinuation { continuation in
                    stopContinuation = continuation
                }
            },
            terminate: { calls.append("terminate") }
        )

        let first = Task { await subject.requestQuit() }
        await waitUntil({ stopContinuation != nil }, message: "first stop never started")
        let second = Task { await subject.requestQuit() }
        await Task.yield()

        try require(calls == ["stop"], "concurrent request started another stop: \(calls)")
        stopContinuation?.resume(returning: true)
        let firstResult = await first.value
        let secondResult = await second.value

        try require(firstResult && secondResult, "coalesced requests disagreed on success")
        try require(
            calls == ["stop", "terminate"],
            "coalesced requests did not terminate exactly once: \(calls)"
        )
    }

    private static func testCancellationCannotTerminateBeforeStopSucceeds() async throws {
        var calls: [String] = []
        var stopContinuation: CheckedContinuation<Bool, Never>?
        let subject = ApplicationQuitCoordinator(
            stopBackground: {
                calls.append("stop")
                return await withCheckedContinuation { continuation in
                    stopContinuation = continuation
                }
            },
            terminate: { calls.append("terminate") }
        )

        let request = Task { await subject.requestQuit() }
        await waitUntil({ stopContinuation != nil }, message: "cancellable stop never started")
        request.cancel()
        await Task.yield()

        try require(
            calls == ["stop"],
            "cancellation terminated before background stop succeeded: \(calls)"
        )
        stopContinuation?.resume(returning: true)
        let result = await request.value

        try require(result, "successful shared stop was lost after caller cancellation")
        try require(
            calls == ["stop", "terminate"],
            "successful stop did not terminate after cancellation: \(calls)"
        )
    }

    private static func waitUntil(
        _ condition: () -> Bool,
        message: String
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        if !condition() {
            fatalError(message)
        }
    }
}
