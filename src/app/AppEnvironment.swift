import Foundation

enum AppEnvironmentMode: Equatable {
    case source
    case release
}

enum AppEnvironmentError: Error, Equatable, LocalizedError {
    case unexpectedArguments(Int)
    case sourceProject(ProjectLocatorError)
    case resourcesDirectoryUnavailable(String)
    case defaultConfigurationUnavailable(String)
    case supportDirectoryUnavailable(String)
    case configurationDirectoryUnavailable(String)
    case configurationFileUnavailable(String)
    case dataDirectoryUnavailable(String)
    case logsDirectoryUnavailable(String)
    case configurationCopyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedArguments(let count):
            return "启动参数无效（收到 \(count) 个）。"
        case .sourceProject(let error):
            return error.localizedDescription
        case .resourcesDirectoryUnavailable(let path):
            return "应用资源目录不可用：\(path)"
        case .defaultConfigurationUnavailable(let path):
            return "应用默认配置不可用：\(path)"
        case .supportDirectoryUnavailable(let path):
            return "应用支持目录不可用：\(path)"
        case .configurationDirectoryUnavailable(let path):
            return "配置目录不可用：\(path)"
        case .configurationFileUnavailable(let path):
            return "配置文件不可用：\(path)"
        case .dataDirectoryUnavailable(let path):
            return "数据目录不可用：\(path)"
        case .logsDirectoryUnavailable(let path):
            return "日志目录不可用：\(path)"
        case .configurationCopyFailed(let path):
            return "无法创建初始配置：\(path)"
        }
    }
}

struct AppEnvironment {
    let mode: AppEnvironmentMode
    let resourcesURL: URL
    let supportURL: URL
    let configURL: URL
    let dataURL: URL
    let logsURL: URL
    let runtimeExecutableURL: URL

    static func resolve(
        arguments: [String],
        bundleURL: URL,
        applicationSupportURL: URL,
        fileManager: FileManager
    ) throws -> AppEnvironment {
        switch arguments.count {
        case 1:
            return try resolveRelease(
                bundleURL: bundleURL,
                applicationSupportURL: applicationSupportURL,
                fileManager: fileManager
            )
        case 2:
            return try resolveSource(
                arguments: [arguments[0], arguments[1]],
                fileManager: fileManager
            )
        case 3 where arguments[1] == "--source-root":
            return try resolveSource(
                arguments: [arguments[0], arguments[2]],
                fileManager: fileManager
            )
        default:
            throw AppEnvironmentError.unexpectedArguments(max(arguments.count - 1, 0))
        }
    }

    private static func resolveSource(
        arguments: [String],
        fileManager: FileManager
    ) throws -> AppEnvironment {
        let location: ProjectLocation
        do {
            location = try ProjectLocator.locate(
                arguments: arguments,
                fileManager: fileManager
            )
        } catch let error as ProjectLocatorError {
            throw AppEnvironmentError.sourceProject(error)
        }

        let root = location.projectURL
        return AppEnvironment(
            mode: .source,
            resourcesURL: root,
            supportURL: root,
            configURL: root.appendingPathComponent("config/config.json"),
            dataURL: location.dataURL,
            logsURL: root.appendingPathComponent("logs", isDirectory: true),
            runtimeExecutableURL: root.appendingPathComponent(".venv/bin/python")
        )
    }

    private static func resolveRelease(
        bundleURL: URL,
        applicationSupportURL: URL,
        fileManager: FileManager
    ) throws -> AppEnvironment {
        let resolvedBundleURL = bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resourcesURL = resolvedBundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isDirectory(resourcesURL, fileManager: fileManager),
              isStrictDescendant(resourcesURL, of: resolvedBundleURL) else {
            throw AppEnvironmentError.resourcesDirectoryUnavailable(resourcesURL.path)
        }

        let defaultConfigURL = resourcesURL.appendingPathComponent(
            "defaults/config.json"
        )
        guard isFile(defaultConfigURL, fileManager: fileManager) else {
            throw AppEnvironmentError.defaultConfigurationUnavailable(defaultConfigURL.path)
        }

        let supportRootURL = applicationSupportURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isDirectory(supportRootURL, fileManager: fileManager) else {
            throw AppEnvironmentError.supportDirectoryUnavailable(applicationSupportURL.path)
        }

        let unresolvedSupportURL = supportRootURL.appendingPathComponent(
            "Mac Face Lock",
            isDirectory: true
        )
        if !fileManager.fileExists(atPath: unresolvedSupportURL.path) {
            do {
                try fileManager.createDirectory(
                    at: unresolvedSupportURL,
                    withIntermediateDirectories: false
                )
            } catch {
                throw AppEnvironmentError.supportDirectoryUnavailable(unresolvedSupportURL.path)
            }
        }

        let supportURL = unresolvedSupportURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isDirectory(supportURL, fileManager: fileManager),
              isStrictDescendant(supportURL, of: supportRootURL) else {
            throw AppEnvironmentError.supportDirectoryUnavailable(unresolvedSupportURL.path)
        }

        let configDirectoryURL = try createOwnedDirectory(
            supportURL.appendingPathComponent("config", isDirectory: true),
            ownedBy: supportURL,
            error: AppEnvironmentError.configurationDirectoryUnavailable,
            fileManager: fileManager
        )
        let dataURL = try createOwnedDirectory(
            supportURL.appendingPathComponent("data", isDirectory: true),
            ownedBy: supportURL,
            error: AppEnvironmentError.dataDirectoryUnavailable,
            fileManager: fileManager
        )
        let logsURL = try createOwnedDirectory(
            supportURL.appendingPathComponent("logs", isDirectory: true),
            ownedBy: supportURL,
            error: AppEnvironmentError.logsDirectoryUnavailable,
            fileManager: fileManager
        )
        let unresolvedConfigURL = configDirectoryURL.appendingPathComponent("config.json")
        let configURL: URL

        if fileManager.fileExists(atPath: unresolvedConfigURL.path) {
            configURL = unresolvedConfigURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard isRegularFile(configURL, fileManager: fileManager),
                  isStrictDescendant(configURL, of: supportURL) else {
                throw AppEnvironmentError.configurationFileUnavailable(
                    unresolvedConfigURL.path
                )
            }
        } else {
            do {
                try fileManager.copyItem(at: defaultConfigURL, to: unresolvedConfigURL)
            } catch {
                throw AppEnvironmentError.configurationCopyFailed(unresolvedConfigURL.path)
            }
            configURL = unresolvedConfigURL
        }

        return AppEnvironment(
            mode: .release,
            resourcesURL: resourcesURL,
            supportURL: supportURL,
            configURL: configURL,
            dataURL: dataURL,
            logsURL: logsURL,
            runtimeExecutableURL: resourcesURL.appendingPathComponent(
                "runtime/MacFaceLockRuntime/MacFaceLockRuntime"
            )
        )
    }

    private static func createOwnedDirectory(
        _ unresolvedURL: URL,
        ownedBy rootURL: URL,
        error makeError: (String) -> AppEnvironmentError,
        fileManager: FileManager
    ) throws -> URL {
        if !fileManager.fileExists(atPath: unresolvedURL.path) {
            do {
                try fileManager.createDirectory(
                    at: unresolvedURL,
                    withIntermediateDirectories: false
                )
            } catch {
                throw makeError(unresolvedURL.path)
            }
        }

        let resolvedURL = unresolvedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isDirectory(resolvedURL, fileManager: fileManager),
              isStrictDescendant(resolvedURL, of: rootURL) else {
            throw makeError(unresolvedURL.path)
        }
        return resolvedURL
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count else {
            return false
        }
        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }
}
