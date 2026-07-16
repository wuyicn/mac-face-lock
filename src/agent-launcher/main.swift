import Darwin
import Foundation

enum AgentLaunchError: Error, Equatable {
    case missingProjectArgument
    case invalidProjectDirectory(String)
    case missingVirtualEnvironment(String)
    case missingAgent(String)
    case argumentAllocationFailed
}

struct LaunchFailureDetails: Equatable {
    let message: String
    let exitCode: Int32
}

func resolveAgentLaunch(arguments: [String]) throws -> (python: String, agent: String) {
    guard arguments.count == 2 else {
        throw AgentLaunchError.missingProjectArgument
    }

    let projectArgument = arguments[1]
    var isDirectory = ObjCBool(false)
    guard projectArgument.hasPrefix("/"),
          FileManager.default.fileExists(atPath: projectArgument, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw AgentLaunchError.invalidProjectDirectory(projectArgument)
    }

    let root = URL(fileURLWithPath: projectArgument, isDirectory: true).standardizedFileURL
    let python = root.appendingPathComponent(".venv/bin/python").path
    let agent = root.appendingPathComponent("agent.py").path
    guard FileManager.default.isExecutableFile(atPath: python) else {
        throw AgentLaunchError.missingVirtualEnvironment(python)
    }
    guard FileManager.default.fileExists(atPath: agent) else {
        throw AgentLaunchError.missingAgent(agent)
    }
    return (python, agent)
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
    case .invalidProjectDirectory(let path):
        return LaunchFailureDetails(message: "invalid project directory: \(path)", exitCode: 64)
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
            let values = [launch.python, "-u", launch.agent]
            var pointers = try makeExecArguments(values: values)
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
