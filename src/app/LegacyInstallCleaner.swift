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

private struct LegacyCleanupJournal: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let rootPath: String
    let rootIdentity: SecureFileIdentity
    let relativeTargets: [String]
    var phase: LegacyCleanupPhase
}

private enum LegacyCleanupPhase: String, Codable {
    case confirmed
    case servicesStopped
    case sourceTargetsRemoved
    case plistsRemoved
}

private enum LegacyCleanupError: Error {
    case invalidJournal
    case couldNotWriteJournal
    case serviceStillLoaded(String)
    case verificationFailed(String)
}

private struct LegacyCleanupCompletion: Codable, Equatable {
    let schemaVersion: Int
    let completed: Bool
}

private enum LegacyCleanupRecord {
    case journal(LegacyCleanupJournal)
    case completed
}

private func readSecureData(
    tree: SecureFileTree,
    name: String
) throws -> Data {
    try tree.readRegularFile(
        name,
        maximumBytes: LegacyIdentity.maximumPlistBytes
    )
}

private final class LegacyCleanupJournalStore {
    private static let maximumBytes = 64 * 1_024
    private static let completionData = Data(
        #"{"schema_version":1,"completed":true}"#.utf8
    )

    private let homeURL: URL
    private let supportURL: URL
    private let journalURL: URL
    private let userID: uid_t

    init(homeURL: URL, supportURL: URL, userID: uid_t) {
        self.homeURL = homeURL
        self.supportURL = supportURL
        self.journalURL = supportURL.appendingPathComponent(
            "legacy-cleanup-v1.json"
        )
        self.userID = userID
    }

    func save(
        _ candidate: LegacyCleanupCandidate,
        phase: LegacyCleanupPhase
    ) throws {
        try save(
            LegacyCleanupJournal(
                schemaVersion: LegacyCleanupJournal.currentSchemaVersion,
                rootPath: candidate.rootURL.path,
                rootIdentity: candidate.rootIdentity,
                relativeTargets: LegacyIdentity.targets,
                phase: phase
            )
        )
    }

    func advance(to phase: LegacyCleanupPhase) throws {
        guard case .journal(var journal) = try load() else {
            throw LegacyCleanupError.invalidJournal
        }
        journal.phase = phase
        try save(journal)
    }

    func finishWithoutLegacyPath() throws {
        try atomicWrite(Self.completionData)
    }

    func load() throws -> LegacyCleanupRecord {
        let initialStat = try validatedJournalStat()
        let tree = try validatedSupportTree()
        let data = try readSecureData(
            tree: tree,
            name: journalURL.lastPathComponent
        )
        let finalStat = try validatedJournalStat()
        guard
            initialStat.st_dev == finalStat.st_dev,
            initialStat.st_ino == finalStat.st_ino
        else {
            throw LegacyCleanupError.invalidJournal
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let completion = try? decoder.decode(
            LegacyCleanupCompletion.self,
            from: data
        ), completion == LegacyCleanupCompletion(
            schemaVersion: LegacyCleanupJournal.currentSchemaVersion,
            completed: true
        ), hasExactKeys(data, expected: ["schema_version", "completed"]) {
            return .completed
        }

        guard
            let journal = try? decoder.decode(
                LegacyCleanupJournal.self,
                from: data
            ),
            hasExactKeys(
                data,
                expected: [
                    "schema_version",
                    "root_path",
                    "root_identity",
                    "relative_targets",
                    "phase",
                ]
            ),
            journal.schemaVersion == LegacyCleanupJournal.currentSchemaVersion,
            journal.relativeTargets == LegacyIdentity.targets,
            validatedRootURL(journal.rootPath) != nil
        else {
            throw LegacyCleanupError.invalidJournal
        }
        return .journal(journal)
    }

    private func save(_ journal: LegacyCleanupJournal) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(journal) else {
            throw LegacyCleanupError.couldNotWriteJournal
        }
        try atomicWrite(data)
    }

    private func atomicWrite(_ data: Data) throws {
        guard data.count <= Self.maximumBytes else {
            throw LegacyCleanupError.couldNotWriteJournal
        }
        _ = try validatedSupportTree()

        let temporaryURL = supportURL.appendingPathComponent(
            ".legacy-cleanup-\(UUID().uuidString).tmp"
        )
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
        let fileDescriptor = Darwin.open(
            temporaryURL.path,
            flags,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw LegacyCleanupError.couldNotWriteJournal
        }

        var shouldClose = true
        var shouldRemoveTemporary = true
        defer {
            if shouldClose {
                Darwin.close(fileDescriptor)
            }
            if shouldRemoveTemporary {
                _ = Darwin.unlink(temporaryURL.path)
            }
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return
                }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(
                        fileDescriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw LegacyCleanupError.couldNotWriteJournal
                    }
                    guard written > 0 else {
                        throw LegacyCleanupError.couldNotWriteJournal
                    }
                    offset += written
                }
            }
            guard Darwin.fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw LegacyCleanupError.couldNotWriteJournal
            }
            guard Darwin.fsync(fileDescriptor) == 0 else {
                throw LegacyCleanupError.couldNotWriteJournal
            }
            let closeResult = Darwin.close(fileDescriptor)
            shouldClose = false
            guard closeResult == 0 else {
                throw LegacyCleanupError.couldNotWriteJournal
            }
            guard Darwin.rename(temporaryURL.path, journalURL.path) == 0 else {
                throw LegacyCleanupError.couldNotWriteJournal
            }
            shouldRemoveTemporary = false
        } catch {
            throw LegacyCleanupError.couldNotWriteJournal
        }
    }

    private func validatedSupportTree() throws -> SecureFileTree {
        do {
            return try SecureFileTree(
                rootURL: supportURL,
                requiredAncestorURL: homeURL,
                requiredOwner: userID
            )
        } catch {
            throw LegacyCleanupError.invalidJournal
        }
    }

    private func validatedJournalStat() throws -> stat {
        var result = stat()
        guard lstat(journalURL.path, &result) == 0 else {
            throw LegacyCleanupError.invalidJournal
        }
        guard
            result.st_uid == userID,
            result.st_mode & S_IFMT == S_IFREG,
            result.st_nlink == 1,
            result.st_mode & 0o777 == 0o600,
            result.st_size >= 0,
            result.st_size <= Self.maximumBytes
        else {
            throw LegacyCleanupError.invalidJournal
        }
        return result
    }

    private func validatedRootURL(_ path: String) -> URL? {
        guard path.hasPrefix("/") else {
            return nil
        }
        let rootURL = URL(
            fileURLWithPath: path,
            isDirectory: true
        ).standardizedFileURL
        guard
            rootURL.path == path,
            rootURL.path != homeURL.path,
            rootURL.path.hasPrefix(homeURL.path + "/")
        else {
            return nil
        }
        return rootURL
    }

    private func hasExactKeys(_ data: Data, expected: Set<String>) -> Bool {
        guard
            let dictionary = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return false
        }
        return Set(dictionary.keys) == expected
    }
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
    private let journalStore: LegacyCleanupJournalStore

    private var launchAgentsURL: URL {
        homeURL.appendingPathComponent(
            "Library/LaunchAgents",
            isDirectory: true
        )
    }

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
        self.journalStore = LegacyCleanupJournalStore(
            homeURL: self.homeURL,
            supportURL: self.supportURL,
            userID: userID
        )
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
        do {
            try preflightAllTargetsWithoutMutation(candidate)
        } catch {
            return .ambiguous("旧版安装内容无法安全预检，未执行任何清理。")
        }

        do {
            try journalStore.save(candidate, phase: .confirmed)
        } catch {
            return .ambiguous("无法安全创建旧版清理记录，未执行任何清理。")
        }

        do {
            try await stopAndVerify(LegacyIdentity.statusLabel)
            try await stopAndVerify(LegacyIdentity.agentLabel)
            try journalStore.advance(to: .servicesStopped)
            try preflightAllRemainingTargetsWithoutMutation(candidate)
            try removeSourceTargets(candidate)
            try journalStore.advance(to: .sourceTargetsRemoved)
            try removeLegacyPlists(candidate)
            try journalStore.advance(to: .plistsRemoved)
            try await verifyEverythingAbsent(candidate)
            try journalStore.finishWithoutLegacyPath()
            return .notFound
        } catch {
            return .cleanupIncomplete(
                "旧版清理未完成。已安全保留进度，请重试清理。"
            )
        }
    }

    func retry() async -> LegacyCleanupInspection {
        let journal: LegacyCleanupJournal
        do {
            switch try journalStore.load() {
            case .completed:
                return .notFound
            case .journal(let loadedJournal):
                journal = loadedJournal
            }
            try preflightRetryWithoutMutation(journal)
        } catch {
            return .ambiguous("旧版清理记录无效，未继续执行清理。")
        }

        do {
            try await stopAndVerify(LegacyIdentity.statusLabel)
            try await stopAndVerify(LegacyIdentity.agentLabel)
            if journal.phase == .confirmed {
                try journalStore.advance(to: .servicesStopped)
            }

            try preflightRetryWithoutMutation(journal)
            try removeSourceTargets(
                rootURL: URL(
                    fileURLWithPath: journal.rootPath,
                    isDirectory: true
                ),
                rootIdentity: journal.rootIdentity
            )
            if journal.phase == .confirmed || journal.phase == .servicesStopped {
                try journalStore.advance(to: .sourceTargetsRemoved)
            }

            try removeLegacyPlistsForRetry(
                rootURL: URL(
                    fileURLWithPath: journal.rootPath,
                    isDirectory: true
                )
            )
            if journal.phase != .plistsRemoved {
                try journalStore.advance(to: .plistsRemoved)
            }

            try await verifyEverythingAbsent(
                rootURL: URL(
                    fileURLWithPath: journal.rootPath,
                    isDirectory: true
                ),
                rootIdentity: journal.rootIdentity
            )
            try journalStore.finishWithoutLegacyPath()
            return .notFound
        } catch {
            return .cleanupIncomplete(
                "旧版清理未完成。已安全保留进度，请重试清理。"
            )
        }
    }

    private func preflightRetryWithoutMutation(
        _ journal: LegacyCleanupJournal
    ) throws {
        let rootURL = URL(
            fileURLWithPath: journal.rootPath,
            isDirectory: true
        )
        let tree = try sourceTree(
            rootURL: rootURL,
            rootIdentity: journal.rootIdentity
        )
        _ = try tree.preflight(
            relativeTargets: LegacyIdentity.targets,
            budget: .legacyCleanup
        )
        try validateRemainingLegacyPlists(rootURL: rootURL)
    }

    private func preflightAllTargetsWithoutMutation(
        _ candidate: LegacyCleanupCandidate
    ) throws {
        guard inspect() == .confirmed(candidate) else {
            throw LegacyCleanupError.verificationFailed("candidate")
        }
        let tree = try sourceTree(for: candidate)
        _ = try tree.preflight(
            relativeTargets: LegacyIdentity.targets,
            budget: .legacyCleanup
        )
        try verifyLegacyPlistIdentities(candidate)
    }

    private func preflightAllRemainingTargetsWithoutMutation(
        _ candidate: LegacyCleanupCandidate
    ) throws {
        let tree = try sourceTree(for: candidate)
        _ = try tree.preflight(
            relativeTargets: LegacyIdentity.targets,
            budget: .legacyCleanup
        )
        try verifyLegacyPlistIdentities(candidate)
    }

    private func removeSourceTargets(
        _ candidate: LegacyCleanupCandidate
    ) throws {
        try removeSourceTargets(
            rootURL: candidate.rootURL,
            rootIdentity: candidate.rootIdentity
        )
    }

    private func removeSourceTargets(
        rootURL: URL,
        rootIdentity: SecureFileIdentity
    ) throws {
        let tree = try sourceTree(
            rootURL: rootURL,
            rootIdentity: rootIdentity
        )
        let manifest = try tree.preflight(
            relativeTargets: LegacyIdentity.targets,
            budget: .legacyCleanup
        )
        try tree.remove(manifest)
    }

    private func removeLegacyPlists(
        _ candidate: LegacyCleanupCandidate
    ) throws {
        let tree = try launchAgentsTree()
        try verifyLegacyPlistIdentities(candidate, tree: tree)
        for name in [LegacyIdentity.statusPlist, LegacyIdentity.agentPlist] {
            let manifest = try tree.preflight(
                relativeTargets: [name],
                budget: plistBudget
            )
            try tree.remove(manifest)
        }
    }

    private func removeLegacyPlistsForRetry(rootURL: URL) throws {
        try validateRemainingLegacyPlists(rootURL: rootURL)
        let tree = try launchAgentsTree()
        for name in [LegacyIdentity.statusPlist, LegacyIdentity.agentPlist] {
            let manifest = try tree.preflight(
                relativeTargets: [name],
                budget: plistBudget
            )
            try tree.remove(manifest)
        }
    }

    private func verifyEverythingAbsent(
        _ candidate: LegacyCleanupCandidate
    ) async throws {
        try await verifyEverythingAbsent(
            rootURL: candidate.rootURL,
            rootIdentity: candidate.rootIdentity
        )
    }

    private func verifyEverythingAbsent(
        rootURL: URL,
        rootIdentity: SecureFileIdentity
    ) async throws {
        try await verifyUnloaded(LegacyIdentity.statusLabel)
        try await verifyUnloaded(LegacyIdentity.agentLabel)

        let sourceManifest = try sourceTree(
            rootURL: rootURL,
            rootIdentity: rootIdentity
        ).preflight(
            relativeTargets: LegacyIdentity.targets,
            budget: .legacyCleanup
        )
        guard sourceManifest.entriesDeepestFirst.isEmpty else {
            throw LegacyCleanupError.verificationFailed("source targets")
        }

        let plistManifest = try launchAgentsTree().preflight(
            relativeTargets: [
                LegacyIdentity.agentPlist,
                LegacyIdentity.statusPlist,
            ],
            budget: plistBudget
        )
        guard plistManifest.entriesDeepestFirst.isEmpty else {
            throw LegacyCleanupError.verificationFailed("legacy plists")
        }
    }

    private func sourceTree(
        for candidate: LegacyCleanupCandidate
    ) throws -> SecureFileTree {
        try sourceTree(
            rootURL: candidate.rootURL,
            rootIdentity: candidate.rootIdentity
        )
    }

    private func sourceTree(
        rootURL: URL,
        rootIdentity: SecureFileIdentity
    ) throws -> SecureFileTree {
        let tree = try SecureFileTree(
            rootURL: rootURL,
            requiredAncestorURL: homeURL,
            requiredOwner: userID
        )
        guard tree.rootIdentity == rootIdentity else {
            throw LegacyCleanupError.verificationFailed("source root")
        }
        return tree
    }

    private func launchAgentsTree() throws -> SecureFileTree {
        try SecureFileTree(
            rootURL: launchAgentsURL,
            requiredAncestorURL: homeURL,
            requiredOwner: userID
        )
    }

    private var plistBudget: SecureTreeBudget {
        SecureTreeBudget(
            maximumEntries: 2,
            maximumLogicalBytes: UInt64(LegacyIdentity.maximumPlistBytes) * 2
        )
    }

    private func verifyLegacyPlistIdentities(
        _ candidate: LegacyCleanupCandidate,
        tree: SecureFileTree? = nil
    ) throws {
        let tree = try tree ?? launchAgentsTree()
        let manifest = try tree.preflight(
            relativeTargets: [
                LegacyIdentity.agentPlist,
                LegacyIdentity.statusPlist,
            ],
            budget: plistBudget
        )
        let identities = Dictionary(
            uniqueKeysWithValues: manifest.entriesDeepestFirst.map {
                ($0.relativePath, $0.identity)
            }
        )
        guard
            identities[LegacyIdentity.agentPlist]
                == candidate.agentPlistIdentity,
            identities[LegacyIdentity.statusPlist]
                == candidate.statusPlistIdentity
        else {
            throw LegacyCleanupError.verificationFailed("legacy plists")
        }
    }

    private func validateRemainingLegacyPlists(rootURL: URL) throws {
        guard let snapshot = try readLegacyPlists() else {
            return
        }
        if let agentData = snapshot.dataByName[LegacyIdentity.agentPlist] {
            guard case .source(let sourceRoot) = parseAgent(agentData),
                  sourceRoot == rootURL else {
                throw LegacyCleanupError.verificationFailed("legacy Agent plist")
            }
        }
        if let statusData = snapshot.dataByName[LegacyIdentity.statusPlist] {
            guard case .source(let sourceRoot) = parseStatus(statusData),
                  sourceRoot == rootURL else {
                throw LegacyCleanupError.verificationFailed("legacy Status plist")
            }
        }
    }

    private func stopAndVerify(_ label: String) async throws {
        let domain = "gui/\(userID)"
        let service = "\(domain)/\(label)"
        let bootout = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootout", service],
            timeout: 5
        )
        let printResult = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", service],
            timeout: 5
        )
        guard printResult.exitCode != 0 else {
            let suffix = bootout.exitCode == 0
                ? ""
                : "（停止命令代码 \(bootout.exitCode)）"
            throw LegacyCleanupError.serviceStillLoaded(label + suffix)
        }
    }

    private func verifyUnloaded(_ label: String) async throws {
        let service = "gui/\(userID)/\(label)"
        let result = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", service],
            timeout: 5
        )
        guard result.exitCode != 0 else {
            throw LegacyCleanupError.serviceStillLoaded(label)
        }
    }

    private func readLegacyPlists() throws -> LegacyPlistSnapshot? {
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
            dataByName[name] = try readSecureData(
                tree: tree,
                name: name
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
