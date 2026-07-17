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

private struct RuntimeFixture {
    let root: URL
    let environment: AppEnvironment

    init(script: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-face-lock-runtime-\(UUID().uuidString)", isDirectory: true)
        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let dataURL = supportURL.appendingPathComponent("data", isDirectory: true)
        let logsURL = supportURL.appendingPathComponent("logs", isDirectory: true)
        let executableURL = root.appendingPathComponent("fake-runtime")
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        environment = AppEnvironment(
            mode: .release,
            resourcesURL: resourcesURL,
            supportURL: supportURL,
            configURL: supportURL.appendingPathComponent("config/config.json"),
            dataURL: dataURL,
            logsURL: logsURL,
            runtimeExecutableURL: executableURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@main
struct RuntimeCommandRunnerTests {
    static func main() async throws {
        try await testValidProgressAndExplicitDirectoryArguments()
        try await testMalformedLineIsActionable()
        try await testUnsupportedSchemaAndUnknownEventAreRejected()
        try await testContradictoryTerminalStatusIsRejected()
        try await testLineAndStderrBuffersAreBounded()
        try await testNonzeroExitIsReturnedForRepairMapping()
        try await testCancellationTerminatesChildProcess()
        print("Runtime command runner tests passed")
    }

    private static func testValidProgressAndExplicitDirectoryArguments() async throws {
        let actual = try RuntimeFixture(script: """
        #!/bin/sh
        set -eu
        [ "$1" = "--resources-dir" ]
        [ "$2" = "__RESOURCES__" ]
        [ "$3" = "--support-dir" ]
        [ "$4" = "__SUPPORT__" ]
        [ "$5" = "enroll" ]
        printf '%s\\n' \
          '{"schema_version":1,"event":"enrollment_started","status":"success","message":"started"}' \
          '{"schema_version":1,"event":"enrollment_progress","status":"success","message":"progress","captured_samples":3,"required_samples":8}' \
          '{"schema_version":1,"event":"enrollment_complete","status":"success","message":"complete"}'
        """)
        defer { actual.remove() }
        let executableURL = actual.environment.runtimeExecutableURL
        var script = try String(contentsOf: executableURL, encoding: .utf8)
        script = script.replacingOccurrences(
            of: "__RESOURCES__",
            with: actual.environment.resourcesURL.path
        )
        script = script.replacingOccurrences(
            of: "__SUPPORT__",
            with: actual.environment.supportURL.path
        )
        try Data(script.utf8).write(to: executableURL)

        var received: [RuntimeEvent] = []
        let result = try await RuntimeCommandRunner(environment: actual.environment).run(
            command: .enroll
        ) {
            received.append($0)
        }

        try require(result.exitCode == 0, "valid runtime did not exit successfully")
        try require(
            received.map(\.event)
                == ["enrollment_started", "enrollment_progress", "enrollment_complete"],
            "valid JSON-lines events were not delivered in order"
        )
        try require(received[1].capturedSamples == 3, "captured sample progress was not decoded")
        try require(received[1].requiredSamples == 8, "required sample progress was not decoded")
    }

    private static func testMalformedLineIsActionable() async throws {
        let fixture = try RuntimeFixture(script: """
        #!/bin/sh
        printf '%s\\n' '{"schema_version":1'
        """)
        defer { fixture.remove() }

        do {
            _ = try await RuntimeCommandRunner(environment: fixture.environment).run(
                command: .diagnose
            ) { _ in }
            throw TestFailure.assertion("malformed runtime event was accepted")
        } catch let error as RuntimeCommandRunnerError {
            try require(
                error.errorDescription?.contains("无法解析") == true,
                "malformed event did not produce an actionable localized error"
            )
        }
    }

    private static func testUnsupportedSchemaAndUnknownEventAreRejected() async throws {
        let scripts = [
            """
            #!/bin/sh
            printf '%s\\n' '{"schema_version":2,"event":"diagnosis_complete","status":"success","message":"done"}'
            """,
            """
            #!/bin/sh
            printf '%s\\n' '{"schema_version":1,"event":"template_dump_complete","status":"success","message":"done"}'
            """,
        ]

        for script in scripts {
            let fixture = try RuntimeFixture(script: script)
            defer { fixture.remove() }
            do {
                _ = try await RuntimeCommandRunner(environment: fixture.environment).run(
                    command: .diagnose
                ) { _ in }
                throw TestFailure.assertion("unsupported runtime event was accepted")
            } catch is RuntimeCommandRunnerError {
                continue
            }
        }
    }

    private static func testContradictoryTerminalStatusIsRejected() async throws {
        let fixture = try RuntimeFixture(script: """
        #!/bin/sh
        printf '%s\\n' '{"schema_version":1,"event":"enrollment_complete","status":"error","message":"failed"}'
        exit 0
        """)
        defer { fixture.remove() }

        do {
            _ = try await RuntimeCommandRunner(environment: fixture.environment).run(
                command: .enroll
            ) { _ in }
            throw TestFailure.assertion("contradictory successful terminal status was accepted")
        } catch RuntimeCommandRunnerError.inconsistentSuccessfulExit {
            // Expected.
        }
    }

    private static func testLineAndStderrBuffersAreBounded() async throws {
        let longLineFixture = try RuntimeFixture(script: """
        #!/bin/sh
        /usr/bin/yes x | /usr/bin/tr -d '\\n' | /usr/bin/head -c 262145
        printf '\\n'
        """)
        defer { longLineFixture.remove() }
        do {
            _ = try await RuntimeCommandRunner(environment: longLineFixture.environment).run(
                command: .diagnose
            ) { _ in }
            throw TestFailure.assertion("oversized runtime line was accepted")
        } catch let error as RuntimeCommandRunnerError {
            try require(
                error.errorDescription?.contains("过长") == true,
                "oversized runtime line returned: \(error)"
            )
        }

        let stderrFixture = try RuntimeFixture(script: """
        #!/bin/sh
        /usr/bin/yes e | /usr/bin/head -c 1100000 >&2
        printf '%s\\n' '{"schema_version":1,"event":"runtime_failure","status":"error","message":"failed"}'
        exit 20
        """)
        defer { stderrFixture.remove() }
        let result = try await RuntimeCommandRunner(environment: stderrFixture.environment).run(
            command: .diagnose
        ) { _ in }
        try require(result.stderr.utf8.count <= 1_048_576, "stderr exceeded the 1 MiB limit")
        try require(result.stderrTruncated, "stderr truncation was not surfaced")
    }

    private static func testNonzeroExitIsReturnedForRepairMapping() async throws {
        let fixture = try RuntimeFixture(script: """
        #!/bin/sh
        printf '%s\\n' '{"schema_version":1,"event":"camera_unavailable","status":"error","message":"busy"}'
        printf 'camera busy' >&2
        exit 10
        """)
        defer { fixture.remove() }

        let result = try await RuntimeCommandRunner(environment: fixture.environment).run(
            command: .diagnose
        ) { _ in }
        try require(result.exitCode == 10, "nonzero runtime exit code was lost")
        try require(result.stderr == "camera busy", "stderr was not retained separately")
    }

    private static func testCancellationTerminatesChildProcess() async throws {
        let fixture = try RuntimeFixture(script: """
        #!/bin/sh
        marker="__MARKER__"
        started="__STARTED__"
        trap 'printf terminated > "$marker"; exit 0' TERM
        printf started > "$started"
        printf '%s\\n' '{"schema_version":1,"event":"enrollment_started","status":"success","message":"started"}'
        while :; do :; done
        """)
        defer { fixture.remove() }
        let markerURL = fixture.root.appendingPathComponent("terminated")
        let startedURL = fixture.root.appendingPathComponent("started")
        let executableURL = fixture.environment.runtimeExecutableURL
        var script = try String(contentsOf: executableURL, encoding: .utf8)
        script = script.replacingOccurrences(of: "__MARKER__", with: markerURL.path)
        script = script.replacingOccurrences(of: "__STARTED__", with: startedURL.path)
        try Data(script.utf8).write(to: executableURL)

        let task = Task {
            try await RuntimeCommandRunner(environment: fixture.environment).run(
                command: .enroll
            ) { _ in }
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: startedURL.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(
            FileManager.default.fileExists(atPath: startedURL.path),
            "cancellation fixture never launched"
        )
        task.cancel()

        do {
            _ = try await task.value
            throw TestFailure.assertion("cancelled runtime returned successfully")
        } catch is CancellationError {
            // Expected.
        }

        for _ in 0..<40 where !FileManager.default.fileExists(atPath: markerURL.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(
            FileManager.default.fileExists(atPath: markerURL.path),
            "cancellation did not terminate the runtime child process"
        )
    }
}
