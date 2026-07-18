import Darwin
import CoreFoundation
import Foundation

struct LegacyCleanupCandidate: Equatable, Sendable {
    let rootURL: URL
    let rootIdentity: SecureFileIdentity
    let agentPlistIdentity: SecureFileIdentity
    let statusPlistIdentity: SecureFileIdentity
}

enum LegacyOrphanService: Equatable, Sendable {
    case agent
    case status
}

struct LegacyOrphanRecoveryCandidate: Equatable, Sendable {
    let service: LegacyOrphanService
    let rootURL: URL
    let plistIdentity: SecureFileIdentity
}

enum LegacyCleanupInspection: Equatable, Sendable {
    case notFound
    case confirmed(LegacyCleanupCandidate)
    case ambiguous(String)
    case cleanupIncomplete(String)
    case completed
}

protocol LegacyInstallCleaning: AnyObject {
    func inspect() -> LegacyCleanupInspection
    func inspectRecoverableOrphan() -> LegacyOrphanRecoveryCandidate?
    func removeRecoverableOrphan(
        _ candidate: LegacyOrphanRecoveryCandidate
    ) async -> LegacyCleanupInspection
    func acknowledgeCompletion() throws
    func clean(_ candidate: LegacyCleanupCandidate) async -> LegacyCleanupInspection
    func retry() async -> LegacyCleanupInspection
    func diagnosticMetadata() -> LegacyCleanupDiagnosticMetadata
}

struct LegacyCleanupDiagnosticMetadata: Codable, Equatable {
    let agentPlistPresent: Bool
    let statusPlistPresent: Bool
    let cleanupRecordPresent: Bool
}

extension LegacyInstallCleaning {
    func inspectRecoverableOrphan() -> LegacyOrphanRecoveryCandidate? {
        nil
    }

    func removeRecoverableOrphan(
        _ candidate: LegacyOrphanRecoveryCandidate
    ) async -> LegacyCleanupInspection {
        .ambiguous("当前旧版结构不能安全自动处理。")
    }

    func diagnosticMetadata() -> LegacyCleanupDiagnosticMetadata {
        LegacyCleanupDiagnosticMetadata(
            agentPlistPresent: false,
            statusPlistPresent: false,
            cleanupRecordPresent: false
        )
    }
}

private enum LegacyIdentity {
    static let agentLabel = "com.wuyi.mac-face-lock-agent"
    static let statusLabel = "com.wuyi.mac-face-lock-status"
    static let agentPlist = "com.wuyi.mac-face-lock-agent.plist"
    static let statusPlist = "com.wuyi.mac-face-lock-status.plist"
    static let maximumPlistBytes = 1_048_576
    static let maximumJournalPurgeEntries = 50_000

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
    var tombstones: [SecureTreeTombstone]?
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

private enum LegacyCleanupRecord {
    case journal(LegacyCleanupJournal)
    case completed
}

private enum LegacyCleanupRecordInspection {
    case absent
    case record(LegacyCleanupRecord)
    case invalid
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
    private static let maximumBytes = 32 * 1_024 * 1_024
    private static let completionData = Data(
        #"{"schema_version":1,"completed":true}"#.utf8
    )
    private static let journalName = "legacy-cleanup-v1.json"

    private let homeURL: URL
    private let supportTree: SecureFileTree?
    private let testEventHandler: ((String) throws -> Void)?

    init(
        homeURL: URL,
        supportURL: URL,
        userID: uid_t,
        testEventHandler: ((String) throws -> Void)?
    ) {
        self.homeURL = homeURL
        self.supportTree = try? SecureFileTree(
            rootURL: supportURL,
            requiredAncestorURL: homeURL,
            requiredOwner: userID
        )
        self.testEventHandler = testEventHandler
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
                phase: phase,
                tombstones: nil
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

    func recordTombstones(_ tombstones: [SecureTreeTombstone]) throws {
        guard case .journal(var journal) = try load(),
              journal.phase == .servicesStopped,
              journal.tombstones == nil else {
            throw LegacyCleanupError.invalidJournal
        }
        journal.tombstones = tombstones
        try save(journal)
    }

    func finishWithoutLegacyPath() throws {
        try atomicWrite(Self.completionData)
    }

    func load() throws -> LegacyCleanupRecord {
        guard case .record(let record) = inspect() else {
            throw LegacyCleanupError.invalidJournal
        }
        return record
    }

    func inspect() -> LegacyCleanupRecordInspection {
        guard let supportTree else {
            return .invalid
        }
        let data: Data
        do {
            data = try supportTree.loadValidatedFile(
                Self.journalName,
                maximumBytes: Self.maximumBytes,
                requiredMode: 0o600
            )
        } catch let error as SecureFileTreeError {
            if case .systemCall("fstatat", _, ENOENT) = error {
                return .absent
            }
            return .invalid
        } catch {
            return .invalid
        }

        if data == Self.completionData {
            return .record(.completed)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard
            let journal = try? decoder.decode(
                LegacyCleanupJournal.self,
                from: data
            ),
            hasExactJournalShape(data),
            journal.schemaVersion == LegacyCleanupJournal.currentSchemaVersion,
            journal.relativeTargets == LegacyIdentity.targets,
            validatedRootURL(journal.rootPath) != nil
        else {
            return .invalid
        }
        return .record(.journal(journal))
    }

    func acknowledgeCompletion() throws {
        guard let supportTree else {
            throw LegacyCleanupError.invalidJournal
        }
        let manifest = try supportTree.preflight(
            relativeTargets: [Self.journalName],
            budget: SecureTreeBudget(
                maximumEntries: 1,
                maximumLogicalBytes: UInt64(Self.completionData.count)
            )
        )
        guard !manifest.entriesDeepestFirst.isEmpty else {
            return
        }
        guard manifest.entriesDeepestFirst.count == 1,
              manifest.entriesDeepestFirst[0].kind == .file else {
            throw LegacyCleanupError.invalidJournal
        }
        let data = try supportTree.loadValidatedFile(
            Self.journalName,
            maximumBytes: Self.maximumBytes,
            requiredMode: 0o600
        )
        guard data == Self.completionData else {
            throw LegacyCleanupError.invalidJournal
        }
        try supportTree.remove(manifest)
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
        guard let supportTree else {
            throw LegacyCleanupError.couldNotWriteJournal
        }

        do {
            try supportTree.replaceFileAtomically(
                Self.journalName,
                temporaryName: ".legacy-cleanup-\(UUID().uuidString).tmp",
                data: data,
                maximumBytes: Self.maximumBytes,
                mode: 0o600,
                beforeRename: {
                    try self.testEventHandler?("beforeJournalRename")
                }
            )
        } catch {
            throw LegacyCleanupError.couldNotWriteJournal
        }
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

    private func hasExactJournalShape(_ data: Data) -> Bool {
        guard
            let dictionary = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            Set(dictionary.keys) == [
                "schema_version",
                "root_path",
                "root_identity",
                "relative_targets",
                "phase",
            ] || Set(dictionary.keys) == [
                "schema_version",
                "root_path",
                "root_identity",
                "relative_targets",
                "phase",
                "tombstones",
            ],
            let identity = dictionary["root_identity"] as? [String: Any],
            Set(identity.keys) == ["device", "inode"],
            isExactUnsignedInteger(identity["device"]),
            isExactUnsignedInteger(identity["inode"]),
            hasExactTombstoneShape(dictionary["tombstones"])
        else {
            return false
        }
        return true
    }

    private func hasExactTombstoneShape(_ value: Any?) -> Bool {
        guard let value else {
            return true
        }
        guard let tombstones = value as? [[String: Any]],
              tombstones.count <= LegacyIdentity.targets.count else {
            return false
        }
        var purgeCount = 0
        return tombstones.allSatisfy { tombstone in
            guard Set(tombstone.keys) == [
                "original_relative_path",
                "tombstone_relative_path",
                "identity",
                "kind",
                "purges",
            ],
            let identity = tombstone["identity"] as? [String: Any],
            Set(identity.keys) == ["device", "inode"],
            isExactUnsignedInteger(identity["device"]),
            isExactUnsignedInteger(identity["inode"]),
            let original = tombstone["original_relative_path"] as? String,
            LegacyIdentity.targets.contains(original),
            let moved = tombstone["tombstone_relative_path"] as? String,
            moved.contains(".mac-face-lock-delete-"),
            let kind = tombstone["kind"] as? String,
            ["file", "directory"].contains(kind),
            let purges = tombstone["purges"] as? [[String: Any]],
            !purges.isEmpty
            else {
                return false
            }
            let (nextCount, overflow) = purgeCount.addingReportingOverflow(
                purges.count
            )
            guard !overflow,
                  nextCount <= LegacyIdentity.maximumJournalPurgeEntries,
                  hasExactPurgeShape(
                    purges,
                    originalRoot: original,
                    tombstoneRoot: moved
                  ) else {
                return false
            }
            purgeCount = nextCount
            let originalParent = (original as NSString).deletingLastPathComponent
            let movedParent = (moved as NSString).deletingLastPathComponent
            return originalParent == movedParent
        }
    }

    private func hasExactPurgeShape(
        _ purges: [[String: Any]],
        originalRoot: String,
        tombstoneRoot: String
    ) -> Bool {
        var originalPaths = Set<String>()
        var tombstonePaths = Set<String>()
        var purgePaths = Set<String>()
        return purges.allSatisfy { purge in
            let keys = Set(purge.keys)
            guard keys == [
                "original_relative_path",
                "tombstone_relative_path",
                "purge_relative_path",
                "identity",
                "kind",
            ] || keys == [
                "original_relative_path",
                "tombstone_relative_path",
                "purge_relative_path",
                "identity",
                "kind",
                "file_version",
            ],
            let original = purge["original_relative_path"] as? String,
            original == originalRoot || original.hasPrefix(originalRoot + "/"),
            let tombstone = purge["tombstone_relative_path"] as? String,
            tombstone == tombstoneRoot
                || tombstone.hasPrefix(tombstoneRoot + "/"),
            let final = purge["purge_relative_path"] as? String,
            (final as NSString).lastPathComponent.hasPrefix(
                ".mac-face-lock-purge-"
            ),
            (final as NSString).lastPathComponent
                != ".mac-face-lock-purge-",
            (tombstone as NSString).deletingLastPathComponent
                == (final as NSString).deletingLastPathComponent,
            let identity = purge["identity"] as? [String: Any],
            Set(identity.keys) == ["device", "inode"],
            isExactUnsignedInteger(identity["device"]),
            isExactUnsignedInteger(identity["inode"]),
            let kind = purge["kind"] as? String,
            ["file", "directory"].contains(kind),
            originalPaths.insert(original).inserted,
            tombstonePaths.insert(tombstone).inserted,
            purgePaths.insert(final).inserted else {
                return false
            }
            if kind == "directory" {
                return purge["file_version"] == nil
            }
            guard let version = purge["file_version"] as? [String: Any],
                  Set(version.keys) == [
                    "logical_size",
                    "modification_seconds",
                    "modification_nanoseconds",
                    "change_seconds",
                    "change_nanoseconds",
                  ],
                  isExactUnsignedInteger(version["logical_size"]),
                  isExactSignedInteger(version["modification_seconds"]),
                  isExactSignedInteger(version["modification_nanoseconds"]),
                  isExactSignedInteger(version["change_seconds"]),
                  isExactSignedInteger(version["change_nanoseconds"]) else {
                return false
            }
            return true
        }
    }

    private func isExactUnsignedInteger(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else {
            return false
        }
        let object = number as CFTypeRef
        guard CFGetTypeID(object) != CFBooleanGetTypeID() else {
            return false
        }
        let encoding = String(cString: number.objCType)
        return ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]
            .contains(encoding)
    }

    private func isExactSignedInteger(_ value: Any?) -> Bool {
        isExactUnsignedInteger(value)
    }
}

private struct LegacyPlistSnapshot {
    let dataByName: [String: Data]
    let identityByName: [String: SecureFileIdentity]
    let manifest: SecureTreeManifest
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
    private let testEventHandler: ((String) throws -> Void)?

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
        userID: uid_t = getuid(),
        testEventHandler: ((String) throws -> Void)? = nil
    ) {
        self.homeURL = homeURL.standardizedFileURL
        self.appURL = appURL.standardizedFileURL
        self.supportURL = supportURL.standardizedFileURL
        self.commandRunner = commandRunner
        self.userID = userID
        self.testEventHandler = testEventHandler
        self.journalStore = LegacyCleanupJournalStore(
            homeURL: self.homeURL,
            supportURL: self.supportURL,
            userID: userID,
            testEventHandler: testEventHandler
        )
    }

    func inspect() -> LegacyCleanupInspection {
        switch journalStore.inspect() {
        case .absent:
            break
        case .record(.completed):
            return .completed
        case .record(.journal):
            return .cleanupIncomplete(
                "旧版清理未完成。已安全保留进度，请重试清理。"
            )
        case .invalid:
            return .ambiguous("旧版清理记录无效，无法自动继续。")
        }

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

    func inspectRecoverableOrphan() -> LegacyOrphanRecoveryCandidate? {
        guard case .absent = journalStore.inspect(),
              let snapshot = try? readLegacyPlists() else {
            return nil
        }
        return recoverableOrphan(from: snapshot)
    }

    func removeRecoverableOrphan(
        _ candidate: LegacyOrphanRecoveryCandidate
    ) async -> LegacyCleanupInspection {
        guard inspectRecoverableOrphan() == candidate else {
            return .ambiguous("旧版后台注册已变化，未执行自动处理。")
        }
        let label: String
        switch candidate.service {
        case .agent:
            label = LegacyIdentity.agentLabel
        case .status:
            label = LegacyIdentity.statusLabel
        }

        do {
            try await stopAndVerify(label)
            guard case .absent = journalStore.inspect(),
                  let snapshot = try readLegacyPlists(),
                  recoverableOrphan(from: snapshot) == candidate else {
                throw LegacyCleanupError.verificationFailed(
                    "orphan registration"
                )
            }
            try testEventHandler?("beforeOrphanPlistRemoval")
            try removePlistsBoundToSnapshot(snapshot, requireBoth: false)
            try await verifyUnloaded(label)
            return inspect()
        } catch {
            return .ambiguous(
                "已知旧版后台注册未能安全移除，源数据保持不变，请重新检查。"
            )
        }
    }

    func acknowledgeCompletion() throws {
        try journalStore.acknowledgeCompletion()
    }

    func diagnosticMetadata() -> LegacyCleanupDiagnosticMetadata {
        let snapshot: LegacyPlistSnapshot?
        do {
            snapshot = try readLegacyPlists()
        } catch {
            snapshot = nil
        }
        let names = Set(snapshot?.dataByName.keys.map { $0 } ?? [])
        let cleanupRecordPresent: Bool
        switch journalStore.inspect() {
        case .absent:
            cleanupRecordPresent = false
        case .record, .invalid:
            cleanupRecordPresent = true
        }
        return LegacyCleanupDiagnosticMetadata(
            agentPlistPresent: names.contains(LegacyIdentity.agentPlist),
            statusPlistPresent: names.contains(LegacyIdentity.statusPlist),
            cleanupRecordPresent: cleanupRecordPresent
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
            let tree = try sourceTree(for: candidate)
            let manifest = try preflightAllRemainingTargetsWithoutMutation(
                candidate,
                tree: tree
            )
            let tombstones = try tree.makeTombstones(
                manifest: manifest,
                relativeTargets: LegacyIdentity.targets
            )
            try journalStore.recordTombstones(tombstones)
            try tree.remove(
                manifest,
                tombstones: tombstones,
                afterRename: { _ in
                    try self.testEventHandler?(
                        "afterSourceTombstoneRename"
                    )
                },
                afterFinalRename: { purge in
                    try self.testEventHandler?(
                        "afterSourcePurgeRename:"
                            + purge.originalRelativePath
                    )
                }
            )
            try journalStore.advance(to: .sourceTargetsRemoved)
            try removeLegacyPlists(candidate)
            try journalStore.advance(to: .plistsRemoved)
            try await verifyEverythingAbsent(
                candidate,
                tombstones: tombstones
            )
            try journalStore.finishWithoutLegacyPath()
            return .notFound
        } catch {
            return .cleanupIncomplete(
                "旧版清理未完成。已安全保留进度，请重试清理。"
            )
        }
    }

    func retry() async -> LegacyCleanupInspection {
        var journal: LegacyCleanupJournal
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
                guard case .journal(let advanced) = try journalStore.load() else {
                    throw LegacyCleanupError.invalidJournal
                }
                journal = advanced
            }

            try preflightRetryWithoutMutation(journal)
            let rootURL = URL(
                fileURLWithPath: journal.rootPath,
                isDirectory: true
            )
            let tree = try sourceTree(
                rootURL: rootURL,
                rootIdentity: journal.rootIdentity
            )
            if journal.tombstones == nil {
                let manifest = try tree.preflight(
                    relativeTargets: LegacyIdentity.targets,
                    budget: .legacyCleanup
                )
                let tombstones = try tree.makeTombstones(
                    manifest: manifest,
                    relativeTargets: LegacyIdentity.targets
                )
                try journalStore.recordTombstones(tombstones)
                guard case .journal(let updated) = try journalStore.load() else {
                    throw LegacyCleanupError.invalidJournal
                }
                journal = updated
            }
            try tree.recoverTombstones(
                journal.tombstones ?? [],
                budget: .legacyCleanup,
                afterRename: { _ in
                    try self.testEventHandler?(
                        "afterSourceTombstoneRename"
                    )
                },
                afterFinalRename: { purge in
                    try self.testEventHandler?(
                        "afterSourcePurgeRename:"
                            + purge.originalRelativePath
                    )
                }
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
                rootIdentity: journal.rootIdentity,
                tombstones: journal.tombstones ?? []
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
        try validateNoReleaseSupportOverlap(rootURL: rootURL)
        let tree = try sourceTree(
            rootURL: rootURL,
            rootIdentity: journal.rootIdentity
        )
        try tree.validateTombstoneStates(
            journal.tombstones ?? [],
            budget: .legacyCleanup
        )
        try validateRemainingLegacyPlists(rootURL: rootURL)
    }

    private func preflightAllTargetsWithoutMutation(
        _ candidate: LegacyCleanupCandidate
    ) throws {
        try validateNoReleaseSupportOverlap(rootURL: candidate.rootURL)
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

    private func validateNoReleaseSupportOverlap(
        rootURL: URL
    ) throws {
        for target in LegacyIdentity.targets {
            let targetURL = rootURL.appendingPathComponent(
                target
            ).standardizedFileURL
            guard
                !isEqualOrDescendant(supportURL, of: targetURL),
                !isEqualOrDescendant(targetURL, of: supportURL)
            else {
                throw LegacyCleanupError.verificationFailed(
                    "release support overlap"
                )
            }
        }
    }

    private func preflightAllRemainingTargetsWithoutMutation(
        _ candidate: LegacyCleanupCandidate,
        tree: SecureFileTree
    ) throws -> SecureTreeManifest {
        let manifest = try tree.preflight(
            relativeTargets: LegacyIdentity.targets,
            budget: .legacyCleanup
        )
        try verifyLegacyPlistIdentities(candidate)
        return manifest
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
        let snapshot = try validatedInitialPlistSnapshot(candidate)
        try testEventHandler?("beforeInitialPlistRemoval")
        try removePlistsBoundToSnapshot(
            snapshot,
            requireBoth: true
        )
    }

    private func removeLegacyPlistsForRetry(rootURL: URL) throws {
        let snapshot = try validatedRemainingLegacyPlists(rootURL: rootURL)
        try testEventHandler?("beforeRetryPlistRemoval")
        try removePlistsBoundToSnapshot(
            snapshot,
            requireBoth: false
        )
    }

    private func verifyEverythingAbsent(
        _ candidate: LegacyCleanupCandidate,
        tombstones: [SecureTreeTombstone]
    ) async throws {
        try await verifyEverythingAbsent(
            rootURL: candidate.rootURL,
            rootIdentity: candidate.rootIdentity,
            tombstones: tombstones
        )
    }

    private func verifyEverythingAbsent(
        rootURL: URL,
        rootIdentity: SecureFileIdentity,
        tombstones: [SecureTreeTombstone]
    ) async throws {
        try await verifyUnloaded(LegacyIdentity.statusLabel)
        try await verifyUnloaded(LegacyIdentity.agentLabel)

        let journalDerivedPaths = tombstones.flatMap { tombstone in
            [tombstone.originalRelativePath, tombstone.tombstoneRelativePath]
                + tombstone.purges.map(\.purgeRelativePath)
        }
        let completionTargets = Array(
            Set(LegacyIdentity.targets + journalDerivedPaths)
        ).sorted()
        let sourceManifest = try sourceTree(
            rootURL: rootURL,
            rootIdentity: rootIdentity
        ).preflight(
            relativeTargets: completionTargets,
            budget: .legacyCleanup
        )
        guard sourceManifest.entriesDeepestFirst.isEmpty else {
            throw LegacyCleanupError.verificationFailed("source targets")
        }

        if let snapshot = try readLegacyPlists(),
           !snapshot.dataByName.isEmpty {
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

    private func launchAgentsTreeIfPresent() throws -> SecureFileTree? {
        do {
            return try launchAgentsTree()
        } catch SecureFileTreeError.systemCall(_, _, let code) where code == ENOENT {
            return nil
        }
    }

    private var plistBudget: SecureTreeBudget {
        SecureTreeBudget(
            maximumEntries: 2,
            maximumLogicalBytes: UInt64(LegacyIdentity.maximumPlistBytes) * 2
        )
    }

    private func verifyLegacyPlistIdentities(
        _ candidate: LegacyCleanupCandidate
    ) throws {
        _ = try validatedInitialPlistSnapshot(candidate)
    }

    private func validatedInitialPlistSnapshot(
        _ candidate: LegacyCleanupCandidate
    ) throws -> LegacyPlistSnapshot {
        guard let snapshot = try readLegacyPlists() else {
            throw LegacyCleanupError.verificationFailed("legacy plists")
        }
        guard
            snapshot.identityByName[LegacyIdentity.agentPlist]
                == candidate.agentPlistIdentity,
            snapshot.identityByName[LegacyIdentity.statusPlist]
                == candidate.statusPlistIdentity,
            let agentData = snapshot.dataByName[LegacyIdentity.agentPlist],
            let statusData = snapshot.dataByName[LegacyIdentity.statusPlist],
            case .source(let agentRoot) = parseAgent(agentData),
            case .source(let statusRoot) = parseStatus(statusData),
            agentRoot == candidate.rootURL,
            statusRoot == candidate.rootURL
        else {
            throw LegacyCleanupError.verificationFailed("legacy plists")
        }
        return snapshot
    }

    private func validatedRemainingLegacyPlists(
        rootURL: URL
    ) throws -> LegacyPlistSnapshot? {
        guard let snapshot = try readLegacyPlists() else {
            return nil
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
        return snapshot
    }

    private func validateRemainingLegacyPlists(rootURL: URL) throws {
        _ = try validatedRemainingLegacyPlists(rootURL: rootURL)
    }

    private func removePlistsBoundToSnapshot(
        _ snapshot: LegacyPlistSnapshot?,
        requireBoth: Bool
    ) throws {
        let entries = Dictionary(
            uniqueKeysWithValues: (snapshot?.manifest.entriesDeepestFirst ?? [])
                .map { ($0.relativePath, $0) }
        )
        if requireBoth {
            guard
                entries[LegacyIdentity.agentPlist] != nil,
                entries[LegacyIdentity.statusPlist] != nil
            else {
                throw LegacyCleanupError.verificationFailed("legacy plists")
            }
        }
        guard let tree = try launchAgentsTreeIfPresent() else {
            guard entries.isEmpty else {
                throw LegacyCleanupError.verificationFailed("legacy plists")
            }
            return
        }
        for name in [LegacyIdentity.statusPlist, LegacyIdentity.agentPlist] {
            guard let entry = entries[name] else {
                continue
            }
            try tree.remove(
                SecureTreeManifest(
                    rootIdentity: snapshot!.manifest.rootIdentity,
                    entriesDeepestFirst: [entry]
                )
            )
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
        if printResult.exitCode == 0 {
            let suffix = bootout.exitCode == 0
                ? ""
                : "（停止命令代码 \(bootout.exitCode)）"
            throw LegacyCleanupError.serviceStillLoaded(label + suffix)
        }
        guard isExactServiceAbsent(
            printResult,
            service: service,
            label: label
        ) else {
            throw LegacyCleanupError.verificationFailed(
                "launchctl print \(label)"
            )
        }
    }

    private func verifyUnloaded(_ label: String) async throws {
        let service = "gui/\(userID)/\(label)"
        let result = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", service],
            timeout: 5
        )
        if result.exitCode == 0 {
            throw LegacyCleanupError.serviceStillLoaded(label)
        }
        guard isExactServiceAbsent(
            result,
            service: service,
            label: label
        ) else {
            throw LegacyCleanupError.verificationFailed(
                "launchctl print \(label)"
            )
        }
    }

    private func isExactServiceAbsent(
        _ result: ServiceCommandResult,
        service: String,
        label: String
    ) -> Bool {
        guard result.exitCode == 113, result.stdout.isEmpty else {
            return false
        }
        let lines = result.stderr
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let direct = "Could not find service \"\(service)\""
        let domain = "Could not find service \"\(label)\" "
            + "in domain for user gui: \(userID)"
        return lines == ["Bad request.", direct]
            || lines == ["Bad request.", domain]
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
            ),
            manifest: finalManifest
        )
    }

    private func recoverableOrphan(
        from snapshot: LegacyPlistSnapshot
    ) -> LegacyOrphanRecoveryCandidate? {
        guard snapshot.dataByName.count == 1 else {
            return nil
        }

        let service: LegacyOrphanService
        let name: String
        let rootURL: URL
        if let data = snapshot.dataByName[LegacyIdentity.agentPlist],
           case .source(let sourceRoot) = parseAgent(data) {
            service = .agent
            name = LegacyIdentity.agentPlist
            rootURL = sourceRoot
        } else if let data = snapshot.dataByName[LegacyIdentity.statusPlist],
                  case .source(let sourceRoot) = parseStatus(data) {
            service = .status
            name = LegacyIdentity.statusPlist
            rootURL = sourceRoot
        } else {
            return nil
        }

        guard !isEqualOrDescendant(appURL, of: rootURL),
              (try? SecureFileTree(
                rootURL: rootURL,
                requiredAncestorURL: homeURL,
                requiredOwner: userID
              )) != nil,
              let identity = snapshot.identityByName[name] else {
            return nil
        }
        return LegacyOrphanRecoveryCandidate(
            service: service,
            rootURL: rootURL,
            plistIdentity: identity
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
