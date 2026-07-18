import Darwin
import CoreFoundation
import Foundation

struct LegacyCleanupCandidate: Equatable, Sendable {
    let rootURL: URL
    let rootIdentity: SecureFileIdentity
    let agentPlistIdentity: SecureFileIdentity
    let statusPlistIdentity: SecureFileIdentity
}

enum LegacyCleanupInspection: Equatable, Sendable {
    case notFound
    case confirmed(LegacyCleanupCandidate)
    case ambiguous(String)
    case cleanupIncomplete(String)
}

protocol LegacyInstallCleaning: AnyObject {
    func inspect() -> LegacyCleanupInspection
    func clean(_ candidate: LegacyCleanupCandidate) async -> LegacyCleanupInspection
    func retry() async -> LegacyCleanupInspection
}

private enum LegacyIdentity {
    static let agentLabel = "com.wuyi.mac-face-lock-agent"
    static let statusLabel = "com.wuyi.mac-face-lock-status"
    static let agentPlist = "com.wuyi.mac-face-lock-agent.plist"
    static let statusPlist = "com.wuyi.mac-face-lock-status.plist"
    static let maximumPlistBytes = 1_048_576

    static let targets = [
        "config/config.json",
        "data",
        "logs",
        "dist/Mac Face Lock Agent.app",
        "dist/Mac Face Lock.app",
        "dist/Mac Face Lock Status.app",
    ]

    static let sourcePath =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

private struct LegacyPlistSnapshot {
    let dataByName: [String: Data]
    let identityByName: [String: SecureFileIdentity]
}

private enum LegacyAgentKind {
    case source(URL)
    case release
    case invalid(String)
}

private enum LegacyStatusKind {
    case source(URL)
    case invalid(String)
}

final class LegacyInstallCleaner: LegacyInstallCleaning {
    private let homeURL: URL
    private let appURL: URL
    private let supportURL: URL
    private let commandRunner: ServiceCommandRunning
    private let userID: uid_t

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        appURL: URL = Bundle.main.bundleURL,
        supportURL: URL,
        commandRunner: ServiceCommandRunning = BoundedServiceCommandRunner(),
        userID: uid_t = getuid()
    ) {
        self.homeURL = homeURL.standardizedFileURL
        self.appURL = appURL.standardizedFileURL
        self.supportURL = supportURL.standardizedFileURL
        self.commandRunner = commandRunner
        self.userID = userID
    }

    func inspect() -> LegacyCleanupInspection {
        let snapshot: LegacyPlistSnapshot
        do {
            guard let inspected = try readLegacyPlists() else {
                return .notFound
            }
            snapshot = inspected
        } catch {
            return .ambiguous("旧版后台服务文件不安全，无法自动确认。")
        }

        let agentData = snapshot.dataByName[LegacyIdentity.agentPlist]
        let statusData = snapshot.dataByName[LegacyIdentity.statusPlist]
        if agentData == nil, statusData == nil {
            return .notFound
        }
        guard let agentData else {
            return .ambiguous("旧版后台服务配置不完整，无法自动确认。")
        }

        let agentKind = parseAgent(agentData)
        guard let statusData else {
            switch agentKind {
            case .release:
                return .notFound
            case .invalid(let message):
                return .ambiguous(message)
            case .source:
                return .ambiguous("旧版后台服务配置不完整，无法自动确认。")
            }
        }

        guard case .source(let agentRoot) = agentKind else {
            switch agentKind {
            case .invalid(let message):
                return .ambiguous(message)
            case .release:
                return .ambiguous("检测到发行版与源码版后台服务混合配置。")
            case .source:
                preconditionFailure("unreachable source classification")
            }
        }

        let statusKind = parseStatus(statusData)
        guard case .source(let statusRoot) = statusKind else {
            if case .invalid(let message) = statusKind {
                return .ambiguous(message)
            }
            return .ambiguous("检测到未知的旧版后台服务配置。")
        }
        guard agentRoot == statusRoot else {
            return .ambiguous("旧版后台服务不属于同一源码目录。")
        }
        guard !isEqualOrDescendant(appURL, of: agentRoot) else {
            return .ambiguous("当前应用位于旧版源码目录内，无法自动确认。")
        }

        let rootTree: SecureFileTree
        do {
            rootTree = try SecureFileTree(
                rootURL: agentRoot,
                requiredAncestorURL: homeURL,
                requiredOwner: userID
            )
        } catch {
            return .ambiguous("旧版源码目录不在当前用户目录内，无法自动确认。")
        }

        guard
            let agentIdentity = snapshot.identityByName[LegacyIdentity.agentPlist],
            let statusIdentity = snapshot.identityByName[LegacyIdentity.statusPlist]
        else {
            return .ambiguous("旧版后台服务文件在检测期间发生变化。")
        }
        return .confirmed(
            LegacyCleanupCandidate(
                rootURL: agentRoot,
                rootIdentity: rootTree.rootIdentity,
                agentPlistIdentity: agentIdentity,
                statusPlistIdentity: statusIdentity
            )
        )
    }

    func clean(_ candidate: LegacyCleanupCandidate) async -> LegacyCleanupInspection {
        _ = candidate
        return .cleanupIncomplete("旧版清理尚未完成，请稍后重试。")
    }

    func retry() async -> LegacyCleanupInspection {
        .cleanupIncomplete("旧版清理尚未完成，请稍后重试。")
    }

    private func readLegacyPlists() throws -> LegacyPlistSnapshot? {
        let launchAgentsURL = homeURL.appendingPathComponent(
            "Library/LaunchAgents",
            isDirectory: true
        )
        let tree: SecureFileTree
        do {
            tree = try SecureFileTree(
                rootURL: launchAgentsURL,
                requiredAncestorURL: homeURL,
                requiredOwner: userID
            )
        } catch SecureFileTreeError.systemCall(_, _, let code) where code == ENOENT {
            return nil
        }

        let names = [LegacyIdentity.agentPlist, LegacyIdentity.statusPlist]
        let initialManifest = try tree.preflight(
            relativeTargets: names,
            budget: SecureTreeBudget(
                maximumEntries: names.count,
                maximumLogicalBytes: UInt64(LegacyIdentity.maximumPlistBytes) * 2
            )
        )
        let existingNames = Set(
            initialManifest.entriesDeepestFirst.map(\.relativePath)
        )
        var dataByName: [String: Data] = [:]
        for name in names where existingNames.contains(name) {
            dataByName[name] = try tree.readRegularFile(
                name,
                maximumBytes: LegacyIdentity.maximumPlistBytes
            )
        }

        let finalManifest = try tree.preflight(
            relativeTargets: names,
            budget: SecureTreeBudget(
                maximumEntries: names.count,
                maximumLogicalBytes: UInt64(LegacyIdentity.maximumPlistBytes) * 2
            )
        )
        guard finalManifest == initialManifest else {
            throw SecureFileTreeError.identityChanged(launchAgentsURL.path)
        }
        return LegacyPlistSnapshot(
            dataByName: dataByName,
            identityByName: Dictionary(
                uniqueKeysWithValues: finalManifest.entriesDeepestFirst.map {
                    ($0.relativePath, $0.identity)
                }
            )
        )
    }

    private func parseAgent(_ data: Data) -> LegacyAgentKind {
        guard let dictionary = propertyListDictionary(data) else {
            return .invalid("旧版 Agent 配置无法识别。")
        }
        if isExactReleaseAgent(dictionary) {
            return .release
        }

        let expectedKeys: Set<String> = [
            "Label",
            "ProgramArguments",
            "WorkingDirectory",
            "RunAtLoad",
            "KeepAlive",
            "StandardOutPath",
            "StandardErrorPath",
            "EnvironmentVariables",
        ]
        guard Set(dictionary.keys) == expectedKeys,
              dictionary["Label"] as? String == LegacyIdentity.agentLabel,
              exactBoolean(dictionary["RunAtLoad"], equals: true),
              exactBoolean(dictionary["KeepAlive"], equals: true),
              let workingDirectory = dictionary["WorkingDirectory"] as? String,
              let candidateRoot = exactAbsoluteDirectory(workingDirectory),
              dictionary["StandardOutPath"] as? String
                == candidateRoot.appendingPathComponent("logs/agent.out.log").path,
              dictionary["StandardErrorPath"] as? String
                == candidateRoot.appendingPathComponent("logs/agent.err.log").path,
              let arguments = dictionary["ProgramArguments"] as? [String],
              let environment = dictionary["EnvironmentVariables"] as? [String: String]
        else {
            return .invalid("旧版 Agent 配置无法识别。")
        }

        let executable = candidateRoot.appendingPathComponent(
            "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
        ).path
        let currentArguments = [executable, candidateRoot.path]
        let currentEnvironment = [
            "PYTHONUNBUFFERED": "1",
            "PATH": LegacyIdentity.sourcePath,
        ]
        if arguments == currentArguments, environment == currentEnvironment {
            return .source(candidateRoot)
        }

        let historicalArguments = [executable, "-u", "agent.py"]
        let historicalKeys: Set<String> = [
            "PYTHONUNBUFFERED",
            "PATH",
            "PYTHONPATH",
        ]
        guard arguments == historicalArguments,
              Set(environment.keys) == historicalKeys,
              environment["PYTHONUNBUFFERED"] == "1",
              environment["PATH"] == LegacyIdentity.sourcePath,
              let pythonPath = environment["PYTHONPATH"]
        else {
            return .invalid("旧版 Agent 配置无法识别。")
        }

        guard isExactHistoricalPythonPath(
            pythonPath,
            candidateRoot: candidateRoot
        ) else {
            return .invalid("旧版 PYTHONPATH 不属于已知源码环境。")
        }
        return .source(candidateRoot)
    }

    private func parseStatus(_ data: Data) -> LegacyStatusKind {
        guard let dictionary = propertyListDictionary(data) else {
            return .invalid("旧版状态服务配置无法识别。")
        }
        let expectedKeys: Set<String> = [
            "Label",
            "ProgramArguments",
            "WorkingDirectory",
            "RunAtLoad",
            "KeepAlive",
            "StandardOutPath",
            "StandardErrorPath",
        ]
        guard Set(dictionary.keys) == expectedKeys,
              dictionary["Label"] as? String == LegacyIdentity.statusLabel,
              exactBoolean(dictionary["RunAtLoad"], equals: true),
              let workingDirectory = dictionary["WorkingDirectory"] as? String,
              let candidateRoot = exactAbsoluteDirectory(workingDirectory),
              dictionary["StandardOutPath"] as? String
                == candidateRoot.appendingPathComponent("logs/status.out.log").path,
              dictionary["StandardErrorPath"] as? String
                == candidateRoot.appendingPathComponent("logs/status.err.log").path,
              let arguments = dictionary["ProgramArguments"] as? [String]
        else {
            return .invalid("旧版状态服务配置无法识别。")
        }

        let unifiedArguments = [
            candidateRoot.appendingPathComponent(
                "dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock"
            ).path,
            candidateRoot.path,
        ]
        if arguments == unifiedArguments,
           let keepAlive = dictionary["KeepAlive"] as? [String: Any],
           Set(keepAlive.keys) == ["SuccessfulExit"],
           exactBoolean(keepAlive["SuccessfulExit"], equals: false) {
            return .source(candidateRoot)
        }

        let historicalArguments = [
            candidateRoot.appendingPathComponent(
                "dist/Mac Face Lock Status.app/Contents/MacOS/MacFaceLockStatus"
            ).path,
            candidateRoot.path,
        ]
        if arguments == historicalArguments,
           exactBoolean(dictionary["KeepAlive"], equals: true) {
            return .source(candidateRoot)
        }
        return .invalid("旧版状态服务配置无法识别。")
    }

    private func isExactReleaseAgent(_ dictionary: [String: Any]) -> Bool {
        let expectedKeys: Set<String> = [
            "Label",
            "ProgramArguments",
            "WorkingDirectory",
            "RunAtLoad",
            "KeepAlive",
            "ProcessType",
            "StandardOutPath",
            "StandardErrorPath",
        ]
        let arguments = [
            appURL.appendingPathComponent(
                "Contents/Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
            ).path,
            "--resources-dir",
            appURL.appendingPathComponent("Contents/Resources").path,
            "--support-dir",
            supportURL.path,
            "agent",
        ]
        return Set(dictionary.keys) == expectedKeys
            && dictionary["Label"] as? String == LegacyIdentity.agentLabel
            && dictionary["ProgramArguments"] as? [String] == arguments
            && dictionary["WorkingDirectory"] as? String == supportURL.path
            && exactBoolean(dictionary["RunAtLoad"], equals: true)
            && exactBoolean(dictionary["KeepAlive"], equals: true)
            && dictionary["ProcessType"] as? String == "Background"
            && dictionary["StandardOutPath"] as? String
                == supportURL.appendingPathComponent("logs/agent-launchd.log").path
            && dictionary["StandardErrorPath"] as? String
                == supportURL.appendingPathComponent(
                    "logs/agent-launchd.error.log"
                ).path
    }

    private func propertyListDictionary(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private func exactBoolean(_ value: Any?, equals expected: Bool) -> Bool {
        guard let value else {
            return false
        }
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == CFBooleanGetTypeID() else {
            return false
        }
        return value as? Bool == expected
    }

    private func exactAbsoluteDirectory(_ path: String) -> URL? {
        guard path.hasPrefix("/") else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.path == path else {
            return nil
        }
        return url
    }

    private func isExactHistoricalPythonPath(
        _ path: String,
        candidateRoot: URL
    ) -> Bool {
        guard path.hasPrefix("/") else {
            return false
        }
        let canonicalURL = URL(fileURLWithPath: path).standardizedFileURL
        guard canonicalURL.path == path else {
            return false
        }

        let rootComponents = candidateRoot.pathComponents
        let pathComponents = canonicalURL.pathComponents
        guard pathComponents.count == rootComponents.count + 4,
              zip(rootComponents, pathComponents).allSatisfy(==) else {
            return false
        }
        let relativeComponents = pathComponents.dropFirst(rootComponents.count)
        guard relativeComponents[relativeComponents.startIndex] == ".venv",
              relativeComponents[relativeComponents.index(
                  relativeComponents.startIndex,
                  offsetBy: 1
              )] == "lib",
              relativeComponents.last == "site-packages" else {
            return false
        }

        let versionComponent = relativeComponents[
            relativeComponents.index(relativeComponents.startIndex, offsetBy: 2)
        ]
        guard versionComponent.hasPrefix("python") else {
            return false
        }
        let version = versionComponent.dropFirst("python".count)
        let versionParts = version.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return versionParts.count == 2
            && versionParts.allSatisfy {
                !$0.isEmpty && $0.utf8.allSatisfy { byte in
                    byte >= 0x30 && byte <= 0x39
                }
            }
    }

    private func isEqualOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }
}
