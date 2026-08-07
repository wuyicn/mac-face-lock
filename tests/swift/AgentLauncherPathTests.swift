import Foundation

private enum TestFailure: Error {
    case assertion(String)
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure.assertion("\(message): expected \(expected), got \(actual)")
    }
}

private func temporaryProject() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-face-lock-agent-launcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@main
struct AgentLauncherPathTests {
    static func main() throws {
        try testMissingProjectArgument()
        try testMissingVirtualEnvironment()
        try testValidTemporaryProject()
        try testValidReleaseInvocation()
        try testReleaseInvocationRejectsMalformedArguments()
        try testCStringAllocationFailure()
        print("Agent launcher path tests passed")
    }

    private static func testMissingProjectArgument() throws {
        do {
            _ = try resolveAgentLaunch(arguments: ["MacFaceLockAgent"])
            throw TestFailure.assertion("missing project argument did not throw")
        } catch let error as AgentLaunchError {
            try expectEqual(error, .missingProjectArgument, "missing argument error")
        }
    }

    private static func testMissingVirtualEnvironment() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedPython = root.appendingPathComponent(".venv/bin/python").path

        do {
            _ = try resolveAgentLaunch(arguments: ["MacFaceLockAgent", root.path])
            throw TestFailure.assertion("missing virtual environment did not throw")
        } catch let error as AgentLaunchError {
            try expectEqual(
                error,
                .missingVirtualEnvironment(expectedPython),
                "missing virtual environment error"
            )
        }
    }

    private static func testValidTemporaryProject() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = root.appendingPathComponent(".venv/bin/python")
        let agent = root.appendingPathComponent("agent.py")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: python.path
        )
        try "print('ok')\n".write(to: agent, atomically: true, encoding: .utf8)

        let launch = try resolveAgentLaunch(arguments: ["MacFaceLockAgent", root.path])

        try expectEqual(launch.python, python.path, "python path")
        try expectEqual(launch.agent, agent.path, "agent path")
    }

    private static func testValidReleaseInvocation() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent(
            "Mac Face Lock.app/Contents/Resources",
            isDirectory: true
        )
        let support = root.appendingPathComponent("support", isDirectory: true)
        let runtime = resources.appendingPathComponent(
            "runtime/MacFaceLockRuntime/MacFaceLockRuntime"
        )
        try FileManager.default.createDirectory(
            at: runtime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\n".write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtime.path
        )

        let launch = try resolveAgentLaunch(arguments: [
            "MacFaceLockAgent",
            "--resources-dir",
            resources.path,
            "--support-dir",
            support.path,
            "agent",
        ])

        try expectEqual(launch.python, runtime.path, "release runtime path")
        try expectEqual(launch.agent, "agent", "release terminal verb")
        try expectEqual(
            launch.execArguments,
            [
                runtime.path,
                "--resources-dir",
                resources.path,
                "--support-dir",
                support.path,
                "agent",
            ],
            "release executable arguments"
        )
    }

    private static func testReleaseInvocationRejectsMalformedArguments() throws {
        let invalidArguments = [
            ["MacFaceLockAgent", "--resources-dir", "/tmp/resources", "agent"],
            [
                "MacFaceLockAgent", "--support-dir", "/tmp/support",
                "--resources-dir", "/tmp/resources", "agent",
            ],
            [
                "MacFaceLockAgent", "--resources-dir", "/tmp/resources",
                "--support-dir", "/tmp/support", "agent", "extra",
            ],
        ]
        for arguments in invalidArguments {
            do {
                _ = try resolveAgentLaunch(arguments: arguments)
                throw TestFailure.assertion(
                    "malformed release arguments were accepted: \(arguments)"
                )
            } catch AgentLaunchError.missingProjectArgument {
                continue
            } catch AgentLaunchError.invalidReleaseInvocation {
                continue
            }
        }
    }

    private static func testCStringAllocationFailure() throws {
        do {
            _ = try makeExecArguments(values: ["python"], duplicate: { _ in nil })
            throw TestFailure.assertion("nil C string allocation did not throw")
        } catch let error as AgentLaunchError {
            try expectEqual(error, .argumentAllocationFailed, "allocation failure error")
            let failure = launchFailureDetails(for: error)
            try expectEqual(failure.exitCode, 78, "allocation failure exit code")
        }
    }
}
