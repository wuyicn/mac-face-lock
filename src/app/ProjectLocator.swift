import Foundation

enum ProjectLocatorError: Error, Equatable, LocalizedError {
    case missingProjectArgument
    case unexpectedProjectArguments(Int)
    case relativeProjectPath(String)
    case projectDirectoryUnavailable(String)
    case configurationUnavailable(String)
    case dataDirectoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingProjectArgument:
            return "缺少项目目录参数。请重新安装启动项后再试。"
        case .unexpectedProjectArguments(let count):
            return "项目目录参数数量无效（收到 \(count) 个）。请重新安装启动项后再试。"
        case .relativeProjectPath(let path):
            return "项目目录必须是绝对路径：\(path)"
        case .projectDirectoryUnavailable(let path):
            return "项目目录不存在或不是文件夹：\(path)"
        case .configurationUnavailable(let path):
            return "找不到项目配置文件：\(path)"
        case .dataDirectoryUnavailable(let path):
            return "项目数据目录不可用：\(path)"
        }
    }
}

struct ProjectLocation {
    let projectURL: URL
    let dataURL: URL
}

enum ProjectLocator {
    static func locate(
        arguments: [String],
        fileManager: FileManager = .default
    ) throws -> ProjectLocation {
        guard arguments.count >= 2 else {
            throw ProjectLocatorError.missingProjectArgument
        }
        guard arguments.count == 2 else {
            throw ProjectLocatorError.unexpectedProjectArguments(arguments.count - 1)
        }

        let path = arguments[1]
        guard NSString(string: path).isAbsolutePath else {
            throw ProjectLocatorError.relativeProjectPath(path)
        }

        let projectURL = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var projectIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &projectIsDirectory),
              projectIsDirectory.boolValue else {
            throw ProjectLocatorError.projectDirectoryUnavailable(projectURL.path)
        }

        let configurationURL = projectURL.appendingPathComponent("config/config.json")
        var configurationIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: configurationURL.path,
            isDirectory: &configurationIsDirectory
        ), !configurationIsDirectory.boolValue else {
            throw ProjectLocatorError.configurationUnavailable(configurationURL.path)
        }

        let unresolvedDataURL = projectURL.appendingPathComponent("data", isDirectory: true)
        var dataIsDirectory: ObjCBool = false
        if !fileManager.fileExists(
            atPath: unresolvedDataURL.path,
            isDirectory: &dataIsDirectory
        ) {
            do {
                try fileManager.createDirectory(
                    at: unresolvedDataURL,
                    withIntermediateDirectories: false
                )
            } catch {
                throw ProjectLocatorError.dataDirectoryUnavailable(unresolvedDataURL.path)
            }
        }

        let dataURL = unresolvedDataURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard fileManager.fileExists(atPath: dataURL.path, isDirectory: &dataIsDirectory),
              dataIsDirectory.boolValue,
              isStrictDescendant(dataURL, of: projectURL) else {
            throw ProjectLocatorError.dataDirectoryUnavailable(unresolvedDataURL.path)
        }

        return ProjectLocation(projectURL: projectURL, dataURL: dataURL)
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
