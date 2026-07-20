import Foundation

enum UIEventTraceEvent: Equatable, Sendable {
    case appActivation
    case desktopWindowShow(windowNumber: Int, isKey: Bool)
    case leftMouseDown(
        windowNumber: Int,
        locationX: Double,
        locationY: Double,
        keyWindowNumber: Int?
    )
    case leftMouseUp(
        windowNumber: Int,
        locationX: Double,
        locationY: Double,
        keyWindowNumber: Int?
    )
    case securityTestActionEntered
    case securityTestWorkingStateAssigned
    case securityTestCoordinatorBefore
    case securityTestCoordinatorAfter(passed: Bool)
}

private enum UIEventTraceWorkItem: Sendable {
    case record(UIEventTraceEvent, Date)
    case flush(CheckedContinuation<Void, Never>)
}

final class UIEventTraceRecorder: Sendable {
    static let shared: UIEventTraceRecorder = {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: "/dev/null", isDirectory: true)
        return UIEventTraceRecorder(applicationSupportURL: applicationSupportURL)
    }()

    let traceURL: URL

    private let continuation: AsyncStream<UIEventTraceWorkItem>.Continuation
    private let writerTask: Task<Void, Never>

    init(applicationSupportURL: URL) {
        let traceURL = applicationSupportURL
            .appendingPathComponent("Mac Face Lock", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("ui-event-trace.log")
        let (stream, continuation) = AsyncStream.makeStream(
            of: UIEventTraceWorkItem.self,
            bufferingPolicy: .bufferingNewest(4_096)
        )

        self.traceURL = traceURL
        self.continuation = continuation
        self.writerTask = Task.detached(priority: .utility) {
            let writer = UIEventTraceWriter(traceURL: traceURL)
            for await workItem in stream {
                switch workItem {
                case .record(let event, let date):
                    writer.record(event, at: date)
                case .flush(let continuation):
                    continuation.resume()
                }
            }
        }
    }

    func record(_ event: UIEventTraceEvent, at date: Date = Date()) {
        continuation.yield(.record(event, date))
    }

    func flushForTesting() async {
        await withCheckedContinuation { flushContinuation in
            continuation.yield(.flush(flushContinuation))
        }
    }

    deinit {
        continuation.finish()
        writerTask.cancel()
    }
}

private final class UIEventTraceWriter {
    private let traceURL: URL
    private let fileManager = FileManager.default
    private let timestampFormatter: ISO8601DateFormatter

    init(traceURL: URL) {
        self.traceURL = traceURL
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.timestampFormatter = formatter
    }

    func record(_ event: UIEventTraceEvent, at date: Date) {
        let data = Data((line(for: event, at: date) + "\n").utf8)
        do {
            try fileManager.createDirectory(
                at: traceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: traceURL.path) {
                let handle = try FileHandle(forUpdating: traceURL)
                defer { try? handle.close() }
                let endOffset = try handle.seekToEnd()
                if endOffset > 0 {
                    try handle.seek(toOffset: endOffset - 1)
                    let lastByte = try handle.read(upToCount: 1)
                    try handle.seekToEnd()
                    if lastByte != Data([0x0A]) {
                        try handle.write(contentsOf: Data([0x0A]))
                    }
                }
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: traceURL, options: .withoutOverwriting)
            }
        } catch {
            // UI diagnostics are best effort and must never affect app behavior.
        }
    }

    private func line(for event: UIEventTraceEvent, at date: Date) -> String {
        var fields = [
            "timestamp=\(timestampFormatter.string(from: date))",
        ]
        switch event {
        case .appActivation:
            fields.append("event=app_activation")
        case .desktopWindowShow(let windowNumber, let isKey):
            fields.append("event=desktop_window_show")
            fields.append("window_number=\(windowNumber)")
            fields.append("is_key=\(isKey)")
        case .leftMouseDown(
            let windowNumber,
            let locationX,
            let locationY,
            let keyWindowNumber
        ):
            appendMouseFields(
                eventName: "left_mouse_down",
                windowNumber: windowNumber,
                locationX: locationX,
                locationY: locationY,
                keyWindowNumber: keyWindowNumber,
                to: &fields
            )
        case .leftMouseUp(
            let windowNumber,
            let locationX,
            let locationY,
            let keyWindowNumber
        ):
            appendMouseFields(
                eventName: "left_mouse_up",
                windowNumber: windowNumber,
                locationX: locationX,
                locationY: locationY,
                keyWindowNumber: keyWindowNumber,
                to: &fields
            )
        case .securityTestActionEntered:
            fields.append("event=security_test_action_entered")
        case .securityTestWorkingStateAssigned:
            fields.append("event=security_test_working_state_assigned")
        case .securityTestCoordinatorBefore:
            fields.append("event=security_test_coordinator_before")
        case .securityTestCoordinatorAfter(let passed):
            fields.append("event=security_test_coordinator_after")
            fields.append("passed=\(passed)")
        }
        return fields.joined(separator: " ")
    }

    private func appendMouseFields(
        eventName: String,
        windowNumber: Int,
        locationX: Double,
        locationY: Double,
        keyWindowNumber: Int?,
        to fields: inout [String]
    ) {
        fields.append("event=\(eventName)")
        fields.append("window_number=\(windowNumber)")
        fields.append("location_x=\(decimal(locationX))")
        fields.append("location_y=\(decimal(locationY))")
        fields.append("key_window_number=\(keyWindowNumber.map(String.init) ?? "none")")
    }

    private func decimal(_ value: Double) -> String {
        String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }
}
