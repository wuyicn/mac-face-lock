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

private func makeTemporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fixedDate() throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: "2026-07-20T01:02:03.456Z") else {
        throw TestFailure.assertion("fixed test date is invalid")
    }
    return date
}

@main
struct UIEventTraceRecorderTests {
    static func main() throws {
        try testRecorderUsesApplicationSupportTracePath()
        try testLineFormatIsDeterministic()
        try testRecordAppendsCompleteLinesWithoutOverwriting()
        try testRecordToleratesUnwritableTracePath()
        print("UI event trace recorder tests passed")
    }

    private static func testRecorderUsesApplicationSupportTracePath() throws {
        let applicationSupportURL = URL(
            fileURLWithPath: "/tmp/Application Support",
            isDirectory: true
        )
        let recorder = UIEventTraceRecorder(
            applicationSupportURL: applicationSupportURL
        )

        try require(
            recorder.traceURL.path
                == "/tmp/Application Support/Mac Face Lock/logs/ui-event-trace.log",
            "recorder trace path must stay inside the product application support logs"
        )
    }

    private static func testLineFormatIsDeterministic() throws {
        let line = UIEventTraceRecorder.line(
            for: .leftMouseDown(
                windowNumber: 17,
                locationX: 12.25,
                locationY: 98.5,
                keyWindowNumber: 17
            ),
            at: try fixedDate()
        )

        try require(
            line == "timestamp=2026-07-20T01:02:03.456Z event=left_mouse_down "
                + "window_number=17 location_x=12.250 location_y=98.500 "
                + "key_window_number=17",
            "trace line format or field order changed: \(line)"
        )
    }

    private static func testRecordAppendsCompleteLinesWithoutOverwriting() throws {
        let root = try makeTemporaryDirectory(named: "mac-face-lock-ui-trace")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = UIEventTraceRecorder(applicationSupportURL: root)
        try FileManager.default.createDirectory(
            at: recorder.traceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("existing-line-without-newline".utf8).write(to: recorder.traceURL)

        let date = try fixedDate()
        recorder.record(.appActivation, at: date)
        recorder.record(
            .desktopWindowShow(windowNumber: 23, isKey: true),
            at: date
        )

        let contents = try String(contentsOf: recorder.traceURL, encoding: .utf8)
        let expected = """
        existing-line-without-newline
        timestamp=2026-07-20T01:02:03.456Z event=app_activation
        timestamp=2026-07-20T01:02:03.456Z event=desktop_window_show window_number=23 is_key=true

        """
        try require(
            contents == expected,
            "trace append changed existing data or line framing: \(String(reflecting: contents))"
        )
    }

    private static func testRecordToleratesUnwritableTracePath() throws {
        let root = try makeTemporaryDirectory(named: "mac-face-lock-ui-trace-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupportFile = root.appendingPathComponent("not-a-directory")
        let sentinel = Data("preserve-me".utf8)
        try sentinel.write(to: applicationSupportFile)
        let recorder = UIEventTraceRecorder(
            applicationSupportURL: applicationSupportFile
        )

        recorder.record(.securityTestActionEntered, at: try fixedDate())

        let preservedData = try Data(contentsOf: applicationSupportFile)
        try require(
            preservedData == sentinel,
            "failure-tolerant recording modified an unrelated file"
        )
        try require(
            !FileManager.default.fileExists(atPath: recorder.traceURL.path),
            "failure-tolerant recording unexpectedly created a trace below a file"
        )
    }
}
