import Darwin
import Foundation

enum ApplicationLaunchMode: Equatable {
    case interface
    case runtime(RuntimeLaunchResolution)
}

struct RuntimeLaunchResolution: Equatable {
    let executableURL: URL
    let execArguments: [String]
}

enum ApplicationLaunchModeError: Error, Equatable {
    case invalidInvocation
    case invalidResources(String)
    case invalidSupport(String)
    case missingRuntime(String)
    case argumentAllocationFailed
}

func resolveApplicationLaunch(
    arguments: [String],
    bundleURL: URL,
    applicationSupportURL: URL,
    fileManager: FileManager = .default
) throws -> ApplicationLaunchMode {
    guard arguments.count != 1 else {
        return .interface
    }
    guard arguments.count == 7,
          arguments[1] == "--internal-runtime",
          arguments[2] == "--resources-dir",
          arguments[4] == "--support-dir",
          ["agent", "enroll", "diagnose", "verify-owner"].contains(arguments[6]) else {
        throw ApplicationLaunchModeError.invalidInvocation
    }
    guard arguments[3].hasPrefix("/") else {
        throw ApplicationLaunchModeError.invalidResources(arguments[3])
    }
    guard arguments[5].hasPrefix("/") else {
        throw ApplicationLaunchModeError.invalidSupport(arguments[5])
    }

    let bundle = try canonicalDirectory(
        bundleURL,
        error: .invalidResources(bundleURL.path),
        fileManager: fileManager
    )
    let expectedResources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
    let resources = try canonicalDirectory(
        URL(fileURLWithPath: arguments[3], isDirectory: true),
        error: .invalidResources(arguments[3]),
        fileManager: fileManager
    )
    guard resources == expectedResources else {
        throw ApplicationLaunchModeError.invalidResources(arguments[3])
    }

    let supportRoot = try canonicalDirectory(
        applicationSupportURL,
        error: .invalidSupport(applicationSupportURL.path),
        fileManager: fileManager
    )
    let expectedSupport = supportRoot.appendingPathComponent("Mac Face Lock", isDirectory: true)
    let support = try canonicalDirectory(
        URL(fileURLWithPath: arguments[5], isDirectory: true),
        error: .invalidSupport(arguments[5]),
        fileManager: fileManager
    )
    guard support == expectedSupport else {
        throw ApplicationLaunchModeError.invalidSupport(arguments[5])
    }

    let runtime = resources.appendingPathComponent(
        "runtime/MacFaceLockRuntime/MacFaceLockRuntime"
    )
    guard runtime.standardizedFileURL.resolvingSymlinksInPath() == runtime.standardizedFileURL,
          isRegularExecutable(runtime, fileManager: fileManager) else {
        throw ApplicationLaunchModeError.missingRuntime(runtime.path)
    }

    return .runtime(
        RuntimeLaunchResolution(
            executableURL: runtime,
            execArguments: [
                runtime.path,
                "--resources-dir", resources.path,
                "--support-dir", support.path,
                arguments[6],
            ]
        )
    )
}

func makeApplicationExecArguments(
    values: [String],
    duplicate: (String) -> UnsafeMutablePointer<CChar>? = { strdup($0) },
    release: (UnsafeMutablePointer<CChar>) -> Void = { free($0) }
) throws -> [UnsafeMutablePointer<CChar>?] {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    for value in values {
        guard let pointer = duplicate(value) else {
            for allocated in pointers {
                if let allocated {
                    release(allocated)
                }
            }
            throw ApplicationLaunchModeError.argumentAllocationFailed
        }
        pointers.append(pointer)
    }
    pointers.append(nil)
    return pointers
}

private func canonicalDirectory(
    _ url: URL,
    error: ApplicationLaunchModeError,
    fileManager: FileManager
) throws -> URL {
    guard url.path.hasPrefix("/") else {
        throw error
    }
    let canonical = url.standardizedFileURL
    guard canonical.resolvingSymlinksInPath() == canonical else {
        throw error
    }
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw error
    }
    return canonical
}

private func isRegularExecutable(_ url: URL, fileManager: FileManager) -> Bool {
    guard fileManager.isExecutableFile(atPath: url.path),
          let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          attributes[.type] as? FileAttributeType == .typeRegular else {
        return false
    }
    return true
}
