import AppKit
import Darwin

@main
enum MacFaceLockApplication {
    static func main() {
        do {
            let applicationSupportURL = try applicationSupportDirectory()
            let mode = try resolveApplicationLaunch(
                arguments: CommandLine.arguments,
                bundleURL: Bundle.main.bundleURL,
                applicationSupportURL: applicationSupportURL
            )
            switch mode {
            case .interface:
                let app = NSApplication.shared
                let delegate = AppDelegate()
                app.delegate = delegate
                app.run()
            case .runtime(let resolution):
                try execRuntime(resolution)
            }
        } catch let error as ApplicationLaunchModeError {
            let failure = applicationLaunchFailure(for: error)
            reportLaunchFailure(failure.message)
            exit(failure.exitCode)
        } catch {
            reportLaunchFailure("unexpected startup error")
            exit(78)
        }
    }

    private static func applicationSupportDirectory() throws -> URL {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ApplicationLaunchModeError.invalidSupport("Application Support")
        }
        return directory
    }

    private static func execRuntime(_ resolution: RuntimeLaunchResolution) throws {
        var pointers = try makeApplicationExecArguments(values: resolution.execArguments)
        defer {
            for pointer in pointers {
                if let pointer {
                    free(pointer)
                }
            }
        }

        let result = resolution.executableURL.path.withCString { executable in
            pointers.withUnsafeMutableBufferPointer { arguments in
                execv(executable, arguments.baseAddress!)
            }
        }
        if result == -1 {
            reportLaunchFailure("could not start bundled runtime: \(String(cString: strerror(errno)))")
            exit(78)
        }
    }

    private static func applicationLaunchFailure(
        for error: ApplicationLaunchModeError
    ) -> (message: String, exitCode: Int32) {
        switch error {
        case .invalidInvocation:
            return ("invalid internal runtime invocation", 64)
        case .invalidResources(let path):
            return ("invalid bundled resources: \(path)", 78)
        case .invalidSupport(let path):
            return ("invalid application support directory: \(path)", 78)
        case .missingRuntime(let path):
            return ("missing bundled runtime: \(path)", 78)
        case .argumentAllocationFailed:
            return ("could not allocate runtime arguments", 78)
        }
    }

    private static func reportLaunchFailure(_ message: String) {
        FileHandle.standardError.write(Data("Mac Face Lock: \(message)\n".utf8))
    }
}
