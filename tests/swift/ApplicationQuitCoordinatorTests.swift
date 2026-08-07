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
        try await testExternalTerminationCoalescesAndApprovesWithoutRecursion()
        try await testCancelledExternalTerminationDoesNotStop()
        try await testFailedExternalTerminationCancelsAndCanRetry()
        try await testReentrantConfirmationCoalescesAndCancelsOnce()
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

    private static func testExternalTerminationCoalescesAndApprovesWithoutRecursion()
        async throws
    {
        var calls: [String] = []
        var confirmations = 0
        var stopContinuation: CheckedContinuation<Bool, Never>?
        var reentrantDecision: ApplicationTerminationDecision?
        var subject: ApplicationQuitCoordinator!
        subject = ApplicationQuitCoordinator(
            stopBackground: {
                calls.append("stop")
                return await withCheckedContinuation { continuation in
                    stopContinuation = continuation
                }
            },
            terminate: {
                calls.append("terminate")
                reentrantDecision = subject.applicationShouldTerminate {
                    confirmations += 1
                    return true
                }
            },
            cancelTermination: { calls.append("cancel") }
        )

        let firstDecision = subject.applicationShouldTerminate {
            confirmations += 1
            return true
        }
        let secondDecision = subject.applicationShouldTerminate {
            confirmations += 1
            return true
        }
        await waitUntil({ stopContinuation != nil }, message: "external stop never started")

        try require(
            firstDecision == .terminateLater && secondDecision == .terminateLater,
            "external termination was not deferred and coalesced"
        )
        try require(confirmations == 1, "coalesced termination asked twice")
        try require(calls == ["stop"], "coalesced termination started extra work: \(calls)")

        stopContinuation?.resume(returning: true)
        await waitUntil({ reentrantDecision != nil }, message: "termination was not approved")

        try require(
            calls == ["stop", "terminate"],
            "successful external termination did not stop then approve: \(calls)"
        )
        try require(
            reentrantDecision == .terminateNow,
            "approved termination recursively restarted the safe-stop flow"
        )
        try require(confirmations == 1, "approved reentry asked for confirmation again")
    }

    private static func testCancelledExternalTerminationDoesNotStop() async throws {
        var calls: [String] = []
        let subject = ApplicationQuitCoordinator(
            stopBackground: {
                calls.append("stop")
                return true
            },
            terminate: { calls.append("terminate") },
            cancelTermination: { calls.append("cancel") }
        )

        let decision = subject.applicationShouldTerminate { false }
        await Task.yield()

        try require(decision == .terminateCancel, "declined termination was not cancelled")
        try require(calls.isEmpty, "declined termination performed work: \(calls)")
    }

    private static func testFailedExternalTerminationCancelsAndCanRetry() async throws {
        var calls: [String] = []
        var stopResult = false
        let subject = ApplicationQuitCoordinator(
            stopBackground: {
                calls.append("stop")
                return stopResult
            },
            terminate: { calls.append("terminate") },
            cancelTermination: { calls.append("cancel") }
        )

        let failedDecision = subject.applicationShouldTerminate { true }
        await waitUntil({ calls.contains("cancel") }, message: "failed termination was not cancelled")

        try require(
            failedDecision == .terminateLater,
            "confirmed failed termination was not deferred"
        )
        try require(
            calls == ["stop", "cancel"],
            "failed termination did not stay alive: \(calls)"
        )

        stopResult = true
        let retryDecision = subject.applicationShouldTerminate { true }
        await waitUntil({ calls.contains("terminate") }, message: "termination retry never completed")

        try require(retryDecision == .terminateLater, "retry did not begin a new safe stop")
        try require(
            calls == ["stop", "cancel", "stop", "terminate"],
            "failed termination did not release the gate for retry: \(calls)"
        )
    }

    private static func testReentrantConfirmationCoalescesAndCancelsOnce()
        async throws
    {
        var confirmations = 0
        var stops = 0
        var deferredCancellationReplies = 0
        var failureCancellations = 0
        var nestedDecision: ApplicationTerminationDecision?
        var subject: ApplicationQuitCoordinator!
        subject = ApplicationQuitCoordinator(
            stopBackground: {
                stops += 1
                return true
            },
            terminate: {},
            cancelTermination: { failureCancellations += 1 },
            cancelDeferredTermination: {
                deferredCancellationReplies += 1
            }
        )

        let outerDecision = subject.applicationShouldTerminate {
            confirmations += 1
            nestedDecision = subject.applicationShouldTerminate {
                confirmations += 1
                return true
            }
            return false
        }
        await Task.yield()

        try require(
            outerDecision == .terminateCancel,
            "declined outer confirmation did not cancel"
        )
        try require(
            nestedDecision == .terminateLater,
            "reentrant termination did not coalesce behind the open confirmation"
        )
        try require(
            confirmations == 1,
            "reentrant termination opened a second confirmation"
        )
        try require(stops == 0, "reentrant confirmation started a background stop")
        try require(
            deferredCancellationReplies == 1,
            "coalesced cancellation did not resolve exactly one deferred reply"
        )
        try require(
            failureCancellations == 0,
            "declining a coalesced confirmation reported a stop failure"
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
