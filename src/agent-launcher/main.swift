import Darwin
import Foundation

enum AgentLaunchError: Error, Equatable {
    case missingProjectArgument
    case invalidReleaseInvocation
    case invalidProjectDirectory(String)
    case invalidReleaseDirectory(String)
    case missingVirtualEnvironment(String)
    case missingAgent(String)
    case argumentAllocationFailed
}

struct LaunchFailureDetails: Equatable {
    let message: String
    let exitCode: Int32
}

struct AgentLaunchResolution: Equatable {
    let python: String
    let agent: String
    let execArguments: [String]
}

func resolveAgentLaunch(arguments: [String]) throws -> AgentLaunchResolution {
    if arguments.count == 2 {
        let projectArgument = arguments[1]
        var isDirectory = ObjCBool(false)
        guard projectArgument.hasPrefix("/"),
              FileManager.default.fileExists(
                atPath: projectArgument,
                isDirectory: &isDirectory
              ),
              isDirectory.boolValue else {
            throw AgentLaunchError.invalidProjectDirectory(projectArgument)
        }

        let root = URL(
            fileURLWithPath: projectArgument,
            isDirectory: true
        ).standardizedFileURL
        let python = root.appendingPathComponent(".venv/bin/python").path
        let agent = root.appendingPathComponent("agent.py").path
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw AgentLaunchError.missingVirtualEnvironment(python)
        }
        guard FileManager.default.fileExists(atPath: agent) else {
            throw AgentLaunchError.missingAgent(agent)
        }
        return AgentLaunchResolution(
            python: python,
            agent: agent,
            execArguments: [python, "-u", agent]
        )
    }

    guard arguments.count == 6,
          arguments[1] == "--resources-dir",
          arguments[3] == "--support-dir",
          arguments[5] == "agent" else {
        if arguments.count == 1 {
            throw AgentLaunchError.missingProjectArgument
        }
        throw AgentLaunchError.invalidReleaseInvocation
    }

    let resources = try canonicalReleaseDirectory(arguments[2])
    let support = try canonicalReleaseDirectory(arguments[4])
    guard resources.lastPathComponent == "Resources",
          resources.deletingLastPathComponent().lastPathComponent == "Contents",
          resources.deletingLastPathComponent()
            .deletingLastPathComponent().pathExtension == "app" else {
        throw AgentLaunchError.invalidReleaseDirectory(arguments[2])
    }
    let runtime = resources.appendingPathComponent(
        "runtime/MacFaceLockRuntime/MacFaceLockRuntime"
    )
    guard runtime.standardizedFileURL.resolvingSymlinksInPath() == runtime,
          FileManager.default.isExecutableFile(atPath: runtime.path) else {
        throw AgentLaunchError.missingAgent(runtime.path)
    }
    _ = support
    return AgentLaunchResolution(
        python: runtime.path,
        agent: "agent",
        execArguments: [
            runtime.path,
            "--resources-dir",
            resources.path,
            "--support-dir",
            support.path,
            "agent",
        ]
    )
}

private func canonicalReleaseDirectory(_ path: String) throws -> URL {
    guard path.hasPrefix("/") else {
        throw AgentLaunchError.invalidReleaseDirectory(path)
    }
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    guard url.path == path,
          url.resolvingSymlinksInPath() == url else {
        throw AgentLaunchError.invalidReleaseDirectory(path)
    }
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw AgentLaunchError.invalidReleaseDirectory(path)
    }
    return url
}

func makeExecArguments(
    values: [String],
    duplicate: (String) -> UnsafeMutablePointer<CChar>? = { strdup($0) }
) throws -> [UnsafeMutablePointer<CChar>?] {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    for value in values {
        guard let pointer = duplicate(value) else {
            for allocated in pointers {
                free(allocated)
            }
            throw AgentLaunchError.argumentAllocationFailed
        }
        pointers.append(pointer)
    }
    pointers.append(nil)
    return pointers
}

func launchFailureDetails(for error: AgentLaunchError) -> LaunchFailureDetails {
    switch error {
    case .missingProjectArgument:
        return LaunchFailureDetails(
            message: "expected one absolute project directory argument",
            exitCode: 64
        )
    case .invalidReleaseInvocation:
        return LaunchFailureDetails(
            message: "invalid release agent invocation",
            exitCode: 64
        )
    case .invalidProjectDirectory(let path):
        return LaunchFailureDetails(message: "invalid project directory: \(path)", exitCode: 64)
    case .invalidReleaseDirectory(let path):
        return LaunchFailureDetails(
            message: "invalid release directory: \(path)",
            exitCode: 64
        )
    case .missingVirtualEnvironment(let path):
        return LaunchFailureDetails(
            message: "missing executable virtual environment Python: \(path)",
            exitCode: 78
        )
    case .missingAgent(let path):
        return LaunchFailureDetails(message: "missing agent: \(path)", exitCode: 78)
    case .argumentAllocationFailed:
        return LaunchFailureDetails(message: "could not allocate process arguments", exitCode: 78)
    }
}

#if !TESTING
private func report(_ message: String) {
    FileHandle.standardError.write(Data("Mac Face Lock Agent: \(message)\n".utf8))
}

@main
struct AgentLauncher {
    static func main() {
        do {
            let launch = try resolveAgentLaunch(arguments: CommandLine.arguments)
            var pointers = try makeExecArguments(values: launch.execArguments)
            defer {
                for pointer in pointers where pointer != nil {
                    free(pointer)
                }
            }

            let result = launch.python.withCString { executable in
                pointers.withUnsafeMutableBufferPointer { arguments in
                    execv(executable, arguments.baseAddress!)
                }
            }
            if result == -1 {
                report("could not start local agent: \(String(cString: strerror(errno)))")
                exit(78)
            }
        } catch let error as AgentLaunchError {
            let failure = launchFailureDetails(for: error)
            report(failure.message)
            exit(failure.exitCode)
        } catch {
            report("unexpected launcher error: \(error)")
            exit(78)
        }
    }
}
#endif
