import AppKit
import Foundation

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
struct LocalMouseEventMonitorTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mac-face-lock-mouse-monitor-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = UIEventTraceRecorder(applicationSupportURL: root)
        let monitorToken = NSObject()
        var installedHandler: ((NSEvent) -> NSEvent?)?
        var registrationCount = 0
        var registeredMask: NSEvent.EventTypeMask?
        var removedTokens: [Any] = []

        let monitor = LocalMouseEventMonitor(
            recorder: recorder,
            addMonitor: { mask, handler in
                registrationCount += 1
                registeredMask = mask
                installedHandler = handler
                return monitorToken
            },
            removeMonitor: { token in
                removedTokens.append(token)
            },
            keyWindowNumber: { 99 }
        )

        monitor.start()
        monitor.start()
        try require(registrationCount == 1, "monitor registered more than once")
        try require(
            registeredMask == [.leftMouseDown, .leftMouseUp],
            "monitor registered the wrong event mask"
        )
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 12.25, y: 98.5),
            modifierFlags: [],
            timestamp: 123,
            windowNumber: 17,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ), let installedHandler else {
            throw TestFailure.assertion("failed to build or install the test mouse event")
        }

        let returnedEvent = installedHandler(event)
        try require(
            returnedEvent === event,
            "local monitor must return the exact original NSEvent instance"
        )

        monitor.stop()
        monitor.stop()
        try require(removedTokens.count == 1, "monitor token was not removed exactly once")
        try require(
            removedTokens[0] as AnyObject === monitorToken,
            "monitor removed a different token than it registered"
        )

        await recorder.flushForTesting()
        let contents = try String(contentsOf: recorder.traceURL, encoding: .utf8)
        try require(
            contents.contains(
                "event=left_mouse_down window_number=17 "
                    + "location_x=12.250 location_y=98.500 key_window_number=99"
            ),
            "monitor did not capture the bounded scalar mouse fields"
        )
        print("Local mouse event monitor tests passed")
    }
}
