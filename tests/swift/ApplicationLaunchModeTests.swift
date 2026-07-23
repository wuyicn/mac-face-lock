import Darwin
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

private struct ApplicationFixture {
    let root: URL
    let bundle: URL
    let resources: URL
    let runtime: URL
    let supportRoot: URL
    let support: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-face-lock-application-mode-\(UUID().uuidString)", isDirectory: true)
        bundle = root.appendingPathComponent("Mac Face Lock.app")
        resources = bundle.appendingPathComponent("Contents/Resources")
        runtime = resources.appendingPathComponent(
            "runtime/MacFaceLockRuntime/MacFaceLockRuntime"
        )
        supportRoot = root.appendingPathComponent("Application Support")
        support = supportRoot.appendingPathComponent("Mac Face Lock")

        try FileManager.default.createDirectory(
            at: runtime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtime.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func internalArguments(command: String) -> [String] {
        [
            "MacFaceLock",
            "--internal-runtime",
            "--resources-dir", resources.path,
            "--support-dir", support.path,
            command,
        ]
    }
}

@main
struct ApplicationLaunchModeTests {
    static func main() throws {
        try testOrdinaryLaunchUsesInterfaceMode()
        try testAllowedCommandsUseBundledRuntime()
        try testMissingAndUnknownCommandsAreRejected()
        try testRelativePathsAreRejected()
        try testSymlinkedResourcesAreRejected()
        try testBundleExternalResourcesAreRejected()
        try testMismatchedSupportPathIsRejected()
        try testExecArgumentsAppendNil()
        try testExecArgumentFailureReleasesEarlierPointers()
        print("Application launch mode tests passed")
    }

    private static func testOrdinaryLaunchUsesInterfaceMode() throws {
        let fixture = try ApplicationFixture()
        defer { fixture.remove() }

        let launch = try resolveApplicationLaunch(
            arguments: ["MacFaceLock"],
            bundleURL: fixture.bundle,
            applicationSupportURL: fixture.supportRoot
        )

        try require(launch == .interface, "ordinary launch did not use interface mode")
    }

    private static func testAllowedCommandsUseBundledRuntime() throws {
        let fixture = try ApplicationFixture()
        defer { fixture.remove() }

        for command in ["agent", "enroll", "diagnose", "verify-owner"] {
            let launch = try resolveApplicationLaunch(
                arguments: fixture.internalArguments(command: command),
                bundleURL: fixture.bundle,
                applicationSupportURL: fixture.supportRoot
            )
            let expected = RuntimeLaunchResolution(
                executableURL: fixture.runtime,
                execArguments: [
                    fixture.runtime.path,
                    "--resources-dir", fixture.resources.path,
                    "--support-dir", fixture.support.path,
                    command,
                ]
            )
            try require(
                launch == .runtime(expected),
                "\(command) did not resolve to the bundled runtime"
            )
        }
    }

    private static func testMissingAndUnknownCommandsAreRejected() throws {
        let fixture = try ApplicationFixture()
        defer { fixture.remove() }

        let arguments = [
            ["MacFaceLock", "--internal-runtime"],
            fixture.internalArguments(command: "unknown"),
        ]
        for invocation in arguments {
            do {
                _ = try resolveApplicationLaunch(
                    arguments: invocation,
                    bundleURL: fixture.bundle,
                    applicationSupportURL: fixture.supportRoot
                )
                throw TestFailure.assertion("invalid command invocation was accepted: \(invocation)")
            } catch let error as ApplicationLaunchModeError {
                try require(error == .invalidInvocation, "wrong invalid-command error: \(error)")
            }
        }
    }

    private static func testRelativePathsAreRejected() throws {
        let fixture = try ApplicationFixture()
        defer { fixture.remove() }

        var resourcesArguments = fixture.internalArguments(command: "agent")
        resourcesArguments[3] = "relative/resources"
        try expectError(
            resourcesArguments,
            fixture: fixture,
            expected: .invalidResources("relative/resources")
        )

        var supportArguments = fixture.internalArguments(command: "agent")
        supportArguments[5] = "relative/support"
        try expectError(
            supportArguments,
            fixture: fixture,
            expected: .invalidSupport("relative/support")
        )
    }

    private static func testSymlinkedResourcesAreRejected() throws {
        let fixture = try ApplicationFixture()
        defer { fixture.remove() }
        let externalResources = fixture.root.appendingPathComponent("external-resources")
        try FileManager.default.createDirectory(
            at: externalResources.appendingPathComponent("runtime/MacFaceLockRuntime"),
            withIntermediateDirectories: true
        )
        try FileManager.default.removeItem(at: fixture.resources)
        try FileManager.default.createSymbolicLink(
            at: fixture.resources,
            withDestinationURL: externalResources
        )

        try expectError(
            fixture.internalArguments(command: "agent"),
            fixture: fixture,
            expected: .invalidResources(fixture.resources.path)
        )
    }

    private static func testBundleExternalResourcesAreRejected() throws {
        let fixture = try ApplicationFixture()
        defer { fixture.remove() }
        let externalResources = fixture.root.appendingPathComponent("external-resources")
        let externalRuntime = externalResources.appendingPathComponent(
            "runtime/MacFaceLockRuntime/MacFaceLockRuntime"
        )
        try FileManager.default.createDirectory(
            at: externalRuntime.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: externalRuntime,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: externalRuntime.path
        )
        var arguments = fixture.internalArguments(command: "agent")
        arguments[3] = externalResources.path

        try expectError(
            arguments,
            fixture: fixture,
            expected: .invalidResources(externalResources.path)
        )
    }

    private static func testMismatchedSupportPathIsRejected() throws {
        let fixture = try ApplicationFixture()
        defer { fixture.remove() }
        let mismatchedSupport = fixture.supportRoot.appendingPathComponent("Other App")
        try FileManager.default.createDirectory(at: mismatchedSupport, withIntermediateDirectories: true)
        var arguments = fixture.internalArguments(command: "agent")
        arguments[5] = mismatchedSupport.path

        try expectError(
            arguments,
            fixture: fixture,
            expected: .invalidSupport(mismatchedSupport.path)
        )
    }

    private static func testExecArgumentsAppendNil() throws {
        let pointers = try makeApplicationExecArguments(values: ["runtime", "agent"])
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }

        try require(pointers.count == 3, "exec argument array did not include a terminator")
        try require(pointers[2] == nil, "exec argument array did not end with nil")
        try require(String(cString: pointers[0]!) == "runtime", "first exec argument changed")
        try require(String(cString: pointers[1]!) == "agent", "second exec argument changed")
    }

    private static func testExecArgumentFailureReleasesEarlierPointers() throws {
        var released: [UnsafeMutablePointer<CChar>] = []
        var allocationCount = 0

        do {
            _ = try makeApplicationExecArguments(
                values: ["runtime", "--resources-dir", "path"],
                duplicate: { value in
                    allocationCount += 1
                    return allocationCount == 3 ? nil : strdup(value)
                },
                release: { pointer in
                    released.append(pointer)
                    free(pointer)
                }
            )
            throw TestFailure.assertion("nil C string allocation did not throw")
        } catch let error as ApplicationLaunchModeError {
            try require(error == .argumentAllocationFailed, "wrong allocation failure error: \(error)")
        }

        try require(released.count == 2, "earlier C strings were not released after allocation failed")
    }

    private static func expectError(
        _ arguments: [String],
        fixture: ApplicationFixture,
        expected: ApplicationLaunchModeError
    ) throws {
        do {
            _ = try resolveApplicationLaunch(
                arguments: arguments,
                bundleURL: fixture.bundle,
                applicationSupportURL: fixture.supportRoot
            )
            throw TestFailure.assertion("invalid invocation was accepted: \(arguments)")
        } catch let error as ApplicationLaunchModeError {
            try require(error == expected, "wrong invocation error: \(error)")
        }
    }
}
