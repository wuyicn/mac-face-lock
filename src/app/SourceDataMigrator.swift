import Darwin
import CoreFoundation
import CryptoKit
import Foundation

enum MigrationItem: String, CaseIterable, Codable, Hashable {
    case configuration
    case ownerTemplate
    case uiPreferences
    case activityHistory

    fileprivate var sourcePath: String {
        switch self {
        case .configuration:
            return "config/config.json"
        case .ownerTemplate:
            return "data/owner_face.npy"
        case .uiPreferences:
            return "data/ui-preferences.json"
        case .activityHistory:
            return "data/activity.jsonl"
        }
    }

    fileprivate var destinationPath: String {
        sourcePath
    }
}

struct MigrationFileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
}

struct LaunchAgentProvenance: Equatable {
    let url: URL
    let identity: MigrationFileIdentity
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let digest: [UInt8]
}

struct SourceInstallCandidate: Identifiable, Equatable {
    let rootURL: URL
    let availableItems: Set<MigrationItem>
    let rootIdentity: MigrationFileIdentity
    let launchAgentProvenance: LaunchAgentProvenance?

    var id: String {
        rootURL.standardizedFileURL.path
    }

    var displayName: String {
        rootURL.lastPathComponent
    }
}

struct MigrationResult: Equatable {
    let importedItems: Set<MigrationItem>
    let backupURL: URL
}

enum MigrationDecision: Equatable {
    case notRequired
    case pending
    case recoveryFailed
    case imported(MigrationResult)
    case skipped
}

enum SourceDataMigrationError: Error, Equatable, LocalizedError {
    case unsafeSourceRoot
    case unsafeSourceEntry(String)
    case sourceChanged(String)
    case fileTooLarge(String)
    case invalidConfiguration
    case invalidOwnerTemplate
    case invalidPreferences
    case invalidActivityHistory
    case unsafeDestination(String)
    case sourceDestinationOverlap
    case migrationInProgress
    case candidateProvenanceChanged
    case recoveryFailed
    case commitFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .unsafeSourceRoot:
            return "旧版目录不安全或已不可用。"
        case .unsafeSourceEntry(let path):
            return "旧版数据包含不安全的文件：\(path)"
        case .sourceChanged(let path):
            return "导入期间旧版文件发生变化：\(path)"
        case .fileTooLarge(let path):
            return "旧版文件超过安全大小限制：\(path)"
        case .invalidConfiguration:
            return "旧版配置无效，未导入任何数据。"
        case .invalidOwnerTemplate:
            return "旧版本人资料无效，未导入任何数据。"
        case .invalidPreferences:
            return "旧版界面偏好无效，未导入任何数据。"
        case .invalidActivityHistory:
            return "旧版活动记录无效，未导入任何数据。"
        case .unsafeDestination(let path):
            return "新版本地数据目录不安全：\(path)"
        case .sourceDestinationOverlap:
            return "旧版目录与新数据目录重叠，已拒绝导入。"
        case .migrationInProgress:
            return "另一个导入或恢复操作正在进行，请稍后重试。"
        case .candidateProvenanceChanged:
            return "旧版安装来源在选择后发生变化，请重新检查。"
        case .recoveryFailed:
            return "上次导入尚未安全恢复，请重试恢复后再继续。"
        case .commitFailed:
            return "无法提交导入数据，原有数据已恢复。"
        case .rollbackFailed:
            return "导入回滚失败，请不要开启保护并查看日志。"
        }
    }
}

enum MigrationFaultPoint: Equatable {
    case afterStageFileFsync(Int)
    case afterBackupFileFsync(Int)
    case afterPreparedDirectoryFsync
    case afterJournalFileFsync(String, Int)
    case afterJournalRename(String, Int)
    case afterJournalDirectoryFsync(String, Int)
    case afterTargetRename(Int)
    case afterDestinationDirectoryFsync(Int)

}

protocol MigrationCrashFault: Error {}

final class SourceDataMigrator {
    private static let configurationByteLimit = 1 * 1_024 * 1_024
    private static let ownerTemplateByteLimit = 64 * 1_024 * 1_024
    private static let preferencesByteLimit = 64 * 1_024
    private static let activityScanByteLimit = 4 * 1_024 * 1_024
    private static let activityRecordByteLimit = 256 * 1_024
    private static let activityLineLimit = 10_000

    private let fileManager: FileManager
    private let candidateRootURLs: [URL]?
    private let launchAgentDirectoryURL: URL?
    private let faultInjector: ((MigrationFaultPoint) throws -> Void)?

    init(
        fileManager: FileManager = .default,
        candidateRootURLs: [URL]? = nil,
        launchAgentDirectoryURL: URL? = nil,
        faultInjector: ((MigrationFaultPoint) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.candidateRootURLs = candidateRootURLs
        self.launchAgentDirectoryURL = launchAgentDirectoryURL
        self.faultInjector = faultInjector
    }

    func discoverCandidates() -> [SourceInstallCandidate] {
        let descriptors: [(URL, LaunchAgentProvenance?)]
        if let candidateRootURLs {
            descriptors = candidateRootURLs.map { ($0, nil) }
        } else {
            descriptors = legacyCandidateDescriptors()
        }
        var seen = Set<String>()
        return descriptors.compactMap { descriptor -> SourceInstallCandidate? in
            let (root, provenance) = descriptor
            let standardized = root.standardizedFileURL
            guard seen.insert(standardized.path).inserted,
                  let reader = try? SecureSourceReader(rootURL: standardized),
                  reader.isRegularFile("agent.py"),
                  reader.isRegularFile(MigrationItem.configuration.sourcePath),
                  reader.isDirectory("data") else {
                return nil
            }
            var items: Set<MigrationItem> = [.configuration]
            for item in MigrationItem.allCases where item != .configuration {
                if reader.entryExists(item.sourcePath) {
                    items.insert(item)
                }
            }
            return SourceInstallCandidate(
                rootURL: standardized,
                availableItems: items,
                rootIdentity: reader.rootIdentity,
                launchAgentProvenance: provenance
            )
        }
        .sorted { $0.rootURL.path < $1.rootURL.path }
    }

    func recoverPendingImports(destination: URL) throws {
        let session = try DestinationSession(
            destination: destination,
            removeLockWhenDone: true
        )
        try session.recoverPendingTransactions()
    }

    func `import`(
        candidate: SourceInstallCandidate,
        destination: URL
    ) throws -> MigrationResult {
        try rejectOverlap(
            source: candidate.rootURL,
            sourceIdentity: candidate.rootIdentity,
            destination: destination
        )
        try validateProvenance(candidate)
        let reader: SecureSourceReader
        do {
            reader = try SecureSourceReader(rootURL: candidate.rootURL)
        } catch {
            throw SourceDataMigrationError.unsafeSourceRoot
        }
        guard reader.rootIdentity == candidate.rootIdentity else {
            throw SourceDataMigrationError.sourceChanged(".")
        }
        guard reader.isRegularFile("agent.py"),
              reader.isRegularFile(MigrationItem.configuration.sourcePath),
              reader.isDirectory("data") else {
            throw SourceDataMigrationError.unsafeSourceRoot
        }

        let session = try DestinationSession(
            destination: destination,
            removeLockWhenDone: true
        )
        try session.recoverPendingTransactions()
        let payloads = try validatedPayloads(
            candidate: candidate,
            reader: reader
        )
        let transactionID = "import-\(UUID().uuidString.lowercased())"
        do {
            let backupURL = try session.performImport(
                transactionID: transactionID,
                payloads: payloads,
                inject: inject
            )
            return MigrationResult(
                importedItems: Set(payloads.map(\.item)),
                backupURL: backupURL
            )
        } catch let injected as InjectedMigrationFault {
            throw injected.underlying
        }
    }

    private func inject(_ point: MigrationFaultPoint) throws {
        do {
            try faultInjector?(point)
        } catch let crash as MigrationCrashFault {
            throw InjectedMigrationFault(underlying: crash)
        } catch {
            throw error
        }
    }

    private func validatedPayloads(
        candidate: SourceInstallCandidate,
        reader: SecureSourceReader
    ) throws -> [MigrationPayload] {
        var payloads: [MigrationPayload] = []
        for item in MigrationItem.allCases where candidate.availableItems.contains(item) {
            let data: Data
            switch item {
            case .configuration:
                data = try reader.read(
                    item.sourcePath,
                    maximumBytes: Self.configurationByteLimit
                )
                guard Self.isValidConfiguration(data) else {
                    throw SourceDataMigrationError.invalidConfiguration
                }
            case .ownerTemplate:
                data = try reader.read(
                    item.sourcePath,
                    maximumBytes: Self.ownerTemplateByteLimit
                )
                guard NumpyOwnerProfileInspector().inspect(data).isValid else {
                    throw SourceDataMigrationError.invalidOwnerTemplate
                }
            case .uiPreferences:
                data = try reader.read(
                    item.sourcePath,
                    maximumBytes: Self.preferencesByteLimit
                )
                guard Self.isValidPreferences(data) else {
                    throw SourceDataMigrationError.invalidPreferences
                }
            case .activityHistory:
                let tail = try reader.readTail(
                    item.sourcePath,
                    maximumBytes: Self.activityScanByteLimit
                )
                data = try Self.validatedActivityTail(
                    tail.data,
                    startsMidFile: tail.startsMidFile
                )
            }
            payloads.append(MigrationPayload(item: item, data: data))
        }
        return payloads
    }

    private func rejectOverlap(
        source: URL,
        sourceIdentity: MigrationFileIdentity,
        destination: URL
    ) throws {
        let sourceCanonical = source.resolvingSymlinksInPath().standardizedFileURL
        let destinationCanonical = destination
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let sourceComponents = sourceCanonical.pathComponents
        let destinationComponents = destinationCanonical.pathComponents
        let sourcePrefixesDestination =
            destinationComponents.count >= sourceComponents.count
            && zip(sourceComponents, destinationComponents).allSatisfy(==)
        let destinationPrefixesSource =
            sourceComponents.count >= destinationComponents.count
            && zip(destinationComponents, sourceComponents).allSatisfy(==)
        var destinationInfo = stat()
        let sameIdentity = lstat(destinationCanonical.path, &destinationInfo) == 0
            && sourceIdentity == MigrationFileIdentity(destinationInfo)
        guard !sourcePrefixesDestination,
              !destinationPrefixesSource,
              !sameIdentity else {
            throw SourceDataMigrationError.sourceDestinationOverlap
        }
    }

    private func validateProvenance(_ candidate: SourceInstallCandidate) throws {
        guard let provenance = candidate.launchAgentProvenance else {
            return
        }
        guard let snapshot = try? SecureRegularFileSnapshot(
            url: provenance.url,
            maximumBytes: 1 * 1_024 * 1_024
        ), snapshot.identity == provenance.identity,
              snapshot.size == provenance.size,
              snapshot.modifiedSeconds == provenance.modifiedSeconds,
              snapshot.modifiedNanoseconds == provenance.modifiedNanoseconds,
              Array(SHA256.hash(data: snapshot.data)) == provenance.digest else {
            throw SourceDataMigrationError.candidateProvenanceChanged
        }
    }

    private func legacyCandidateDescriptors() -> [(URL, LaunchAgentProvenance?)] {
        let directory = launchAgentDirectoryURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let specifications = [
            (
                name: "com.wuyi.mac-face-lock-agent.plist",
                label: "com.wuyi.mac-face-lock-agent",
                executableSuffix:
                    "/dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
            ),
            (
                name: "com.wuyi.mac-face-lock-status.plist",
                label: "com.wuyi.mac-face-lock-status",
                executableSuffix:
                    "/dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock"
            ),
        ]
        var descriptors: [(URL, LaunchAgentProvenance?)] = []
        for specification in specifications {
            let plistURL = directory.appendingPathComponent(specification.name)
            guard let snapshot = try? SecureRegularFileSnapshot(
                url: plistURL,
                maximumBytes: 1 * 1_024 * 1_024
            ),
                  let object = try? PropertyListSerialization.propertyList(
                      from: snapshot.data,
                      options: [],
                      format: nil
                  ),
                  let dictionary = object as? [String: Any],
                  dictionary["Label"] as? String == specification.label,
                  let arguments = dictionary["ProgramArguments"] as? [String],
                  arguments.count == 2,
                  arguments[1].hasPrefix("/"),
                  arguments[0]
                    == arguments[1] + specification.executableSuffix,
                  dictionary["WorkingDirectory"] as? String == arguments[1] else {
                continue
            }
            descriptors.append(
                (
                    URL(fileURLWithPath: arguments[1]).standardizedFileURL,
                    LaunchAgentProvenance(
                        url: plistURL,
                        identity: snapshot.identity,
                        size: snapshot.size,
                        modifiedSeconds: snapshot.modifiedSeconds,
                        modifiedNanoseconds: snapshot.modifiedNanoseconds,
                        digest: Array(SHA256.hash(data: snapshot.data))
                    )
                )
            )
        }
        return descriptors
    }

    private static func isValidConfiguration(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              !dictionary.isEmpty,
              let mode = dictionary["mode"] as? String,
              ["observe", "balanced", "strict", "presence_guard"].contains(mode)
        else {
            return false
        }
        if let value = dictionary["lock_on_camera_error"] {
            guard isJSONBoolean(value, equalTo: false) else {
                return false
            }
        }
        if let value = dictionary["event_notify_on_lock"] {
            guard isJSONBoolean(value, equalTo: false) else {
                return false
            }
        }
        if let script = dictionary["event_notify_script"] {
            guard let script = script as? String, script.isEmpty else {
                return false
            }
        }
        for key in [
            "cooldown_seconds_after_lock",
            "camera_error_cooldown_seconds",
        ] {
            if let value = dictionary[key] {
                guard let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite,
                      number.doubleValue >= 300 else {
                    return false
                }
            }
        }
        return true
    }

    private static func isJSONBoolean(
        _ value: Any,
        equalTo expected: Bool
    ) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return number.boolValue == expected
    }

    private static func isValidPreferences(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let preferences = try? decoder.decode(UIPreferences.self, from: data),
              preferences.schemaVersion == 1 else {
            return false
        }
        return true
    }

    private static func validatedActivityTail(
        _ data: Data,
        startsMidFile: Bool
    ) throws -> Data {
        var bounded = data
        if startsMidFile {
            guard let newline = bounded.firstIndex(of: 0x0a) else {
                return Data()
            }
            bounded = Data(bounded[bounded.index(after: newline)...])
        }
        guard bounded.isEmpty || bounded.last == 0x0a else {
            throw SourceDataMigrationError.invalidActivityHistory
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var validated = Data()
        var lineStart = bounded.startIndex
        var lineCount = 0
        while lineStart < bounded.endIndex {
            guard let newline = bounded[lineStart...].firstIndex(of: 0x0a) else {
                throw SourceDataMigrationError.invalidActivityHistory
            }
            let line = Data(bounded[lineStart..<newline])
            lineStart = bounded.index(after: newline)
            if line.isEmpty {
                continue
            }
            lineCount += 1
            guard lineCount <= activityLineLimit,
                  line.count <= activityRecordByteLimit,
                  let event = try? decoder.decode(ActivityEvent.self, from: line),
                  event.schemaVersion == 1 else {
                throw SourceDataMigrationError.invalidActivityHistory
            }
            validated.append(line)
            validated.append(0x0a)
        }
        return validated
    }
}

private struct InjectedMigrationFault: Error {
    let underlying: Error
}

private struct MigrationPayload {
    let item: MigrationItem
    let data: Data
}

private enum MigrationJournalState: String, Codable {
    case preparing
    case committing
    case complete
    case rolledBack
}

private struct DurableMigrationJournal: Codable {
    var schemaVersion = 1
    var state: MigrationJournalState
    var intentCount: Int
    var committedCount: Int
    var entries: [DurableMigrationEntry]
}

private struct DurableMigrationEntry: Codable {
    let item: MigrationItem
    let parentName: String
    let targetName: String
    let stageName: String
    let backupName: String?
    let targetExisted: Bool
    let parentIdentity: MigrationFileIdentity
}

private final class RuntimeMigrationEntry {
    let durable: DurableMigrationEntry
    let parentFD: Int32

    init(durable: DurableMigrationEntry, parentFD: Int32) {
        self.durable = durable
        self.parentFD = parentFD
    }

    deinit {
        close(parentFD)
    }
}

private extension MigrationFileIdentity {
    init(_ info: stat) {
        self.init(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }
}

private struct SecureRegularFileSnapshot {
    let data: Data
    let identity: MigrationFileIdentity
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    init(url: URL, maximumBytes: Int) throws {
        let fd = open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw SourceDataMigrationError.unsafeSourceEntry(url.lastPathComponent)
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= off_t(maximumBytes) else {
            throw SourceDataMigrationError.unsafeSourceEntry(url.lastPathComponent)
        }
        let bytes = try readExactData(
            fd: fd,
            count: Int(before.st_size),
            error: SourceDataMigrationError.sourceChanged(url.lastPathComponent)
        )
        var after = stat()
        guard fstat(fd, &after) == 0,
              sameStableFile(before, after) else {
            throw SourceDataMigrationError.sourceChanged(url.lastPathComponent)
        }
        data = bytes
        identity = MigrationFileIdentity(before)
        size = Int64(before.st_size)
        modifiedSeconds = Int64(before.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(before.st_mtimespec.tv_nsec)
    }
}

private final class DestinationSession {
    private let destination: URL
    private let rootFD: Int32
    private let rootIdentity: MigrationFileIdentity
    private let lockFD: Int32
    private let createdLock: Bool
    private let removeLockWhenDone: Bool

    init(destination: URL, removeLockWhenDone: Bool) throws {
        self.destination = destination.standardizedFileURL
        self.removeLockWhenDone = removeLockWhenDone
        var rootInfo = stat()
        guard lstat(self.destination.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw SourceDataMigrationError.unsafeDestination(
                self.destination.path
            )
        }
        let openedRoot = open(
            self.destination.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard openedRoot >= 0 else {
            throw SourceDataMigrationError.unsafeDestination(
                self.destination.path
            )
        }
        var openedRootInfo = stat()
        guard fstat(openedRoot, &openedRootInfo) == 0,
              MigrationFileIdentity(openedRootInfo)
                == MigrationFileIdentity(rootInfo) else {
            close(openedRoot)
            throw SourceDataMigrationError.unsafeDestination(
                self.destination.path
            )
        }
        rootFD = openedRoot
        rootIdentity = MigrationFileIdentity(openedRootInfo)

        var lockInfo = stat()
        let lockAlreadyExisted = fstatat(
            rootFD,
            ".migration.lock",
            &lockInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0
        let openedLock = openat(
            rootFD,
            ".migration.lock",
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard openedLock >= 0 else {
            close(rootFD)
            throw SourceDataMigrationError.unsafeDestination(
                ".migration.lock"
            )
        }
        var openedLockInfo = stat()
        guard fstat(openedLock, &openedLockInfo) == 0,
              (openedLockInfo.st_mode & S_IFMT) == S_IFREG,
              openedLockInfo.st_nlink == 1 else {
            close(openedLock)
            close(rootFD)
            throw SourceDataMigrationError.unsafeDestination(
                ".migration.lock"
            )
        }
        guard flock(openedLock, LOCK_EX | LOCK_NB) == 0 else {
            close(openedLock)
            close(rootFD)
            throw SourceDataMigrationError.migrationInProgress
        }
        lockFD = openedLock
        createdLock = !lockAlreadyExisted
    }

    deinit {
        if removeLockWhenDone && createdLock {
            _ = unlinkat(rootFD, ".migration.lock", 0)
            _ = fsync(rootFD)
        }
        _ = flock(lockFD, LOCK_UN)
        close(lockFD)
        close(rootFD)
    }

    func performImport(
        transactionID: String,
        payloads: [MigrationPayload],
        inject: @escaping (MigrationFaultPoint) throws -> Void
    ) throws -> URL {
        try verifyRoot()
        let backupsWasCreated = try ensureDirectory(
            parentFD: rootFD,
            name: "backups"
        ).created
        let backupsFD = try openDirectory(parentFD: rootFD, name: "backups")
        defer { close(backupsFD) }
        guard mkdirat(backupsFD, transactionID, 0o700) == 0 else {
            throw SourceDataMigrationError.commitFailed
        }
        _ = fsync(backupsFD)
        let transactionFD = try openDirectory(
            parentFD: backupsFD,
            name: transactionID
        )
        defer { close(transactionFD) }
        guard mkdirat(transactionFD, "staging", 0o700) == 0,
              mkdirat(transactionFD, "rollback", 0o700) == 0 else {
            try? secureRemoveDirectory(parentFD: backupsFD, name: transactionID)
            throw SourceDataMigrationError.commitFailed
        }
        let stagingFD = try openDirectory(
            parentFD: transactionFD,
            name: "staging"
        )
        let rollbackFD = try openDirectory(
            parentFD: transactionFD,
            name: "rollback"
        )
        defer {
            close(stagingFD)
            close(rollbackFD)
        }

        var runtimeEntries: [RuntimeMigrationEntry] = []
        do {
            for (payloadIndex, payload) in payloads.enumerated() {
                let mapping = destinationMapping(payload.item)
                let parentFD = try openDirectory(
                    parentFD: rootFD,
                    name: mapping.parent
                )
                var parentInfo = stat()
                guard fstat(parentFD, &parentInfo) == 0 else {
                    close(parentFD)
                    throw SourceDataMigrationError.unsafeDestination(
                        mapping.parent
                    )
                }
                let stageName = "\(payload.item.rawValue).stage"
                try writeNewFile(
                    parentFD: stagingFD,
                    name: stageName,
                    data: payload.data
                )
                try inject(.afterStageFileFsync(payloadIndex))
                let targetInfo = try fileInfo(
                    parentFD: parentFD,
                    name: mapping.target
                )
                let targetExisted = targetInfo != nil
                var backupName: String?
                if let targetInfo {
                    guard (targetInfo.st_mode & S_IFMT) == S_IFREG,
                          targetInfo.st_nlink == 1 else {
                        close(parentFD)
                        throw SourceDataMigrationError.unsafeDestination(
                            "\(mapping.parent)/\(mapping.target)"
                        )
                    }
                    let existing = try readFile(
                        parentFD: parentFD,
                        name: mapping.target,
                        maximumBytes: 64 * 1_024 * 1_024
                    )
                    let name = "\(payload.item.rawValue).backup"
                    try writeNewFile(
                        parentFD: rollbackFD,
                        name: name,
                        data: existing
                    )
                    try inject(.afterBackupFileFsync(payloadIndex))
                    backupName = name
                }
                let durable = DurableMigrationEntry(
                    item: payload.item,
                    parentName: mapping.parent,
                    targetName: mapping.target,
                    stageName: stageName,
                    backupName: backupName,
                    targetExisted: targetExisted,
                    parentIdentity: MigrationFileIdentity(parentInfo)
                )
                runtimeEntries.append(
                    RuntimeMigrationEntry(
                        durable: durable,
                        parentFD: parentFD
                    )
                )
            }
            guard fsync(stagingFD) == 0,
                  fsync(rollbackFD) == 0,
                  fsync(transactionFD) == 0,
                  fsync(backupsFD) == 0 else {
                throw SourceDataMigrationError.commitFailed
            }
            try inject(.afterPreparedDirectoryFsync)

            var journal = DurableMigrationJournal(
                state: .preparing,
                intentCount: 0,
                committedCount: 0,
                entries: runtimeEntries.map(\.durable)
            )
            try writeJournal(
                journal,
                transactionFD: transactionFD,
                checkpoint: "initial",
                index: -1,
                inject: inject
            )

            do {
                for (index, entry) in runtimeEntries.enumerated() {
                    journal.state = .committing
                    journal.intentCount = index + 1
                    try writeJournal(
                        journal,
                        transactionFD: transactionFD,
                        checkpoint: "intent",
                        index: index,
                        inject: inject
                    )
                    guard try parentStillBound(entry) else {
                        throw SourceDataMigrationError.unsafeDestination(
                            entry.durable.parentName
                        )
                    }
                    guard renameat(
                        stagingFD,
                        entry.durable.stageName,
                        entry.parentFD,
                        entry.durable.targetName
                    ) == 0 else {
                        throw SourceDataMigrationError.commitFailed
                    }
                    try inject(.afterTargetRename(index))
                    guard fsync(entry.parentFD) == 0 else {
                        throw SourceDataMigrationError.commitFailed
                    }
                    try inject(.afterDestinationDirectoryFsync(index))
                    journal.committedCount = index + 1
                    try writeJournal(
                        journal,
                        transactionFD: transactionFD,
                        checkpoint: "committed",
                        index: index,
                        inject: inject
                    )
                }
                journal.state = .complete
                try writeJournal(
                    journal,
                    transactionFD: transactionFD,
                    checkpoint: "complete",
                    index: -1,
                    inject: inject
                )
            } catch let injected as InjectedMigrationFault {
                throw injected
            } catch {
                do {
                    try rollback(
                        journal: journal,
                        transactionFD: transactionFD,
                        runtimeEntries: runtimeEntries
                    )
                    journal.state = .rolledBack
                    try writeJournal(journal, transactionFD: transactionFD)
                    try secureRemoveDirectory(
                        parentFD: backupsFD,
                        name: transactionID
                    )
                    if backupsWasCreated {
                        try? removeDirectoryIfEmpty(
                            parentFD: rootFD,
                            name: "backups"
                        )
                    }
                } catch {
                    throw SourceDataMigrationError.rollbackFailed
                }
                throw error
            }
            return destination
                .appendingPathComponent("backups")
                .appendingPathComponent(transactionID)
        } catch let injected as InjectedMigrationFault {
            throw injected
        } catch {
            if (try? readJournal(transactionFD: transactionFD)) == nil {
                try? secureRemoveDirectory(
                    parentFD: backupsFD,
                    name: transactionID
                )
                if backupsWasCreated {
                    try? removeDirectoryIfEmpty(
                        parentFD: rootFD,
                        name: "backups"
                    )
                }
            }
            throw error
        }
    }

    func recoverPendingTransactions() throws {
        try verifyRoot()
        guard let backupsFD = try optionalDirectory(
            parentFD: rootFD,
            name: "backups"
        ) else {
            return
        }
        defer { close(backupsFD) }
        for name in try directoryNames(backupsFD)
            where name.hasPrefix("import-") {
            guard let transactionFD = try optionalDirectory(
                parentFD: backupsFD,
                name: name
            ) else {
                throw SourceDataMigrationError.recoveryFailed
            }
            defer { close(transactionFD) }
            guard try fileInfo(
                parentFD: transactionFD,
                name: "journal.json"
            ) != nil else {
                try secureRemoveDirectory(parentFD: backupsFD, name: name)
                continue
            }
            let journal: DurableMigrationJournal
            do {
                journal = try readJournal(transactionFD: transactionFD)
            } catch {
                throw SourceDataMigrationError.recoveryFailed
            }
            try validateJournal(journal)
            switch journal.state {
            case .complete:
                continue
            case .rolledBack:
                try secureRemoveDirectory(parentFD: backupsFD, name: name)
            case .preparing, .committing:
                let runtimeEntries = try runtimeEntriesForRecovery(journal)
                try rollback(
                    journal: journal,
                    transactionFD: transactionFD,
                    runtimeEntries: runtimeEntries
                )
                var rolledBack = journal
                rolledBack.state = .rolledBack
                try writeJournal(rolledBack, transactionFD: transactionFD)
                try secureRemoveDirectory(parentFD: backupsFD, name: name)
            }
        }
        try? removeDirectoryIfEmpty(parentFD: rootFD, name: "backups")
    }

    private func runtimeEntriesForRecovery(
        _ journal: DurableMigrationJournal
    ) throws -> [RuntimeMigrationEntry] {
        try journal.entries.map { durable in
            let parentFD = try openDirectory(
                parentFD: rootFD,
                name: durable.parentName
            )
            var info = stat()
            guard fstat(parentFD, &info) == 0,
                  MigrationFileIdentity(info) == durable.parentIdentity else {
                close(parentFD)
                throw SourceDataMigrationError.recoveryFailed
            }
            return RuntimeMigrationEntry(
                durable: durable,
                parentFD: parentFD
            )
        }
    }

    private func rollback(
        journal: DurableMigrationJournal,
        transactionFD: Int32,
        runtimeEntries: [RuntimeMigrationEntry]
    ) throws {
        let rollbackFD = try openDirectory(
            parentFD: transactionFD,
            name: "rollback"
        )
        defer { close(rollbackFD) }
        for entry in runtimeEntries.prefix(journal.intentCount).reversed() {
            if entry.durable.targetExisted {
                guard let backupName = entry.durable.backupName else {
                    throw SourceDataMigrationError.rollbackFailed
                }
                let backup = try readFile(
                    parentFD: rollbackFD,
                    name: backupName,
                    maximumBytes: 64 * 1_024 * 1_024
                )
                let temporary = ".rollback-\(UUID().uuidString)"
                try writeNewFile(
                    parentFD: entry.parentFD,
                    name: temporary,
                    data: backup
                )
                guard renameat(
                    entry.parentFD,
                    temporary,
                    entry.parentFD,
                    entry.durable.targetName
                ) == 0 else {
                    _ = unlinkat(entry.parentFD, temporary, 0)
                    throw SourceDataMigrationError.rollbackFailed
                }
            } else if unlinkat(
                entry.parentFD,
                entry.durable.targetName,
                0
            ) != 0, errno != ENOENT {
                throw SourceDataMigrationError.rollbackFailed
            }
            guard fsync(entry.parentFD) == 0 else {
                throw SourceDataMigrationError.rollbackFailed
            }
        }
    }

    private func parentStillBound(
        _ entry: RuntimeMigrationEntry
    ) throws -> Bool {
        var rootEntry = stat()
        guard fstatat(
            rootFD,
            entry.durable.parentName,
            &rootEntry,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return false
        }
        return (rootEntry.st_mode & S_IFMT) == S_IFDIR
            && MigrationFileIdentity(rootEntry) == entry.durable.parentIdentity
    }

    private func writeJournal(
        _ journal: DurableMigrationJournal,
        transactionFD: Int32,
        checkpoint: String? = nil,
        index: Int = -1,
        inject: ((MigrationFaultPoint) throws -> Void)? = nil
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(journal)
        let temporary = ".journal-\(UUID().uuidString)"
        try writeNewFile(
            parentFD: transactionFD,
            name: temporary,
            data: data
        )
        if let checkpoint {
            try inject?(.afterJournalFileFsync(checkpoint, index))
        }
        guard renameat(
            transactionFD,
            temporary,
            transactionFD,
            "journal.json"
        ) == 0 else {
            _ = unlinkat(transactionFD, temporary, 0)
            throw SourceDataMigrationError.commitFailed
        }
        if let checkpoint {
            try inject?(.afterJournalRename(checkpoint, index))
        }
        guard fsync(transactionFD) == 0 else {
            throw SourceDataMigrationError.commitFailed
        }
        if let checkpoint {
            try inject?(.afterJournalDirectoryFsync(checkpoint, index))
        }
    }

    private func readJournal(
        transactionFD: Int32
    ) throws -> DurableMigrationJournal {
        let data = try readFile(
            parentFD: transactionFD,
            name: "journal.json",
            maximumBytes: 1 * 1_024 * 1_024
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DurableMigrationJournal.self, from: data)
    }

    private func validateJournal(
        _ journal: DurableMigrationJournal
    ) throws {
        let allowed = Set(MigrationItem.allCases)
        guard journal.schemaVersion == 1,
              journal.intentCount >= 0,
              journal.intentCount <= journal.entries.count,
              journal.committedCount >= 0,
              journal.committedCount <= journal.intentCount,
              Set(journal.entries.map(\.item)).count == journal.entries.count,
              journal.entries.allSatisfy({
                  allowed.contains($0.item)
                    && $0.parentName == destinationMapping($0.item).parent
                    && $0.targetName == destinationMapping($0.item).target
                    && !$0.stageName.contains("/")
                    && ($0.backupName?.contains("/") != true)
              }) else {
            throw SourceDataMigrationError.recoveryFailed
        }
    }

    private func verifyRoot() throws {
        var info = stat()
        guard fstat(rootFD, &info) == 0,
              MigrationFileIdentity(info) == rootIdentity else {
            throw SourceDataMigrationError.unsafeDestination(".")
        }
    }
}

private func destinationMapping(
    _ item: MigrationItem
) -> (parent: String, target: String) {
    switch item {
    case .configuration:
        return ("config", "config.json")
    case .ownerTemplate:
        return ("data", "owner_face.npy")
    case .uiPreferences:
        return ("data", "ui-preferences.json")
    case .activityHistory:
        return ("data", "activity.jsonl")
    }
}

private func ensureDirectory(
    parentFD: Int32,
    name: String
) throws -> (created: Bool, identity: MigrationFileIdentity) {
    var info = stat()
    if fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw SourceDataMigrationError.unsafeDestination(name)
        }
        return (false, MigrationFileIdentity(info))
    }
    guard errno == ENOENT,
          mkdirat(parentFD, name, 0o700) == 0,
          fsync(parentFD) == 0,
          fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
          (info.st_mode & S_IFMT) == S_IFDIR else {
        throw SourceDataMigrationError.unsafeDestination(name)
    }
    return (true, MigrationFileIdentity(info))
}

private func openDirectory(parentFD: Int32, name: String) throws -> Int32 {
    let fd = openat(
        parentFD,
        name,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard fd >= 0 else {
        throw SourceDataMigrationError.unsafeDestination(name)
    }
    return fd
}

private func optionalDirectory(
    parentFD: Int32,
    name: String
) throws -> Int32? {
    let fd = openat(
        parentFD,
        name,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    if fd >= 0 {
        return fd
    }
    if errno == ENOENT {
        return nil
    }
    throw SourceDataMigrationError.unsafeDestination(name)
}

private func fileInfo(parentFD: Int32, name: String) throws -> stat? {
    var info = stat()
    if fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
        return info
    }
    if errno == ENOENT {
        return nil
    }
    throw SourceDataMigrationError.unsafeDestination(name)
}

private func writeNewFile(
    parentFD: Int32,
    name: String,
    data: Data
) throws {
    let fd = openat(
        parentFD,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0o600
    )
    guard fd >= 0 else {
        throw SourceDataMigrationError.commitFailed
    }
    var succeeded = false
    defer {
        close(fd)
        if !succeeded {
            _ = unlinkat(parentFD, name, 0)
        }
    }
    try data.withUnsafeBytes { bytes in
        var written = 0
        while written < bytes.count {
            let count = Darwin.write(
                fd,
                bytes.baseAddress!.advanced(by: written),
                bytes.count - written
            )
            if count > 0 {
                written += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw SourceDataMigrationError.commitFailed
            }
        }
    }
    guard fsync(fd) == 0 else {
        throw SourceDataMigrationError.commitFailed
    }
    succeeded = true
}

private func readFile(
    parentFD: Int32,
    name: String,
    maximumBytes: Int
) throws -> Data {
    let fd = openat(
        parentFD,
        name,
        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    guard fd >= 0 else {
        throw SourceDataMigrationError.unsafeDestination(name)
    }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0,
          (before.st_mode & S_IFMT) == S_IFREG,
          before.st_nlink == 1,
          before.st_size >= 0,
          before.st_size <= off_t(maximumBytes) else {
        throw SourceDataMigrationError.unsafeDestination(name)
    }
    let data = try readExactData(
        fd: fd,
        count: Int(before.st_size),
        error: SourceDataMigrationError.unsafeDestination(name)
    )
    var after = stat()
    guard fstat(fd, &after) == 0, sameStableFile(before, after) else {
        throw SourceDataMigrationError.unsafeDestination(name)
    }
    return data
}

private func readExactData(
    fd: Int32,
    count: Int,
    error: Error
) throws -> Data {
    var data = Data(count: count)
    var total = 0
    let success = data.withUnsafeMutableBytes { bytes -> Bool in
        if count == 0 {
            return true
        }
        guard let base = bytes.baseAddress else {
            return false
        }
        while total < count {
            let amount = Darwin.read(
                fd,
                base.advanced(by: total),
                count - total
            )
            if amount > 0 {
                total += amount
            } else if amount < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
    guard success else {
        throw error
    }
    return data
}

private func sameStableFile(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev
        && left.st_ino == right.st_ino
        && left.st_mode == right.st_mode
        && left.st_nlink == right.st_nlink
        && left.st_size == right.st_size
        && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
        && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
        && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
        && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
}

private func directoryNames(_ fd: Int32) throws -> [String] {
    let duplicate = dup(fd)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
        if duplicate >= 0 { close(duplicate) }
        throw SourceDataMigrationError.recoveryFailed
    }
    defer { closedir(directory) }
    var names: [String] = []
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
        if name != "." && name != ".." {
            names.append(name)
        }
    }
    return names
}

private func secureRemoveDirectory(parentFD: Int32, name: String) throws {
    let directoryFD = try openDirectory(parentFD: parentFD, name: name)
    defer { close(directoryFD) }
    for child in try directoryNames(directoryFD) {
        var info = stat()
        guard fstatat(
            directoryFD,
            child,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw SourceDataMigrationError.recoveryFailed
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            try secureRemoveDirectory(parentFD: directoryFD, name: child)
        } else if unlinkat(directoryFD, child, 0) != 0 {
            throw SourceDataMigrationError.recoveryFailed
        }
    }
    guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0,
          fsync(parentFD) == 0 else {
        throw SourceDataMigrationError.recoveryFailed
    }
}

private func removeDirectoryIfEmpty(parentFD: Int32, name: String) throws {
    guard let fd = try optionalDirectory(parentFD: parentFD, name: name) else {
        return
    }
    let isEmpty = try directoryNames(fd).isEmpty
    close(fd)
    guard isEmpty else {
        return
    }
    guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0,
          fsync(parentFD) == 0 else {
        throw SourceDataMigrationError.recoveryFailed
    }
}

private final class SecureSourceReader {
    private let rootFD: Int32
    let rootIdentity: MigrationFileIdentity

    init(rootURL: URL) throws {
        var info = stat()
        guard lstat(rootURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            throw SourceDataMigrationError.unsafeSourceRoot
        }
        rootFD = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootFD >= 0 else {
            throw SourceDataMigrationError.unsafeSourceRoot
        }
        var openedInfo = stat()
        guard fstat(rootFD, &openedInfo) == 0,
              MigrationFileIdentity(openedInfo) == MigrationFileIdentity(info) else {
            close(rootFD)
            throw SourceDataMigrationError.unsafeSourceRoot
        }
        rootIdentity = MigrationFileIdentity(openedInfo)
    }

    deinit {
        close(rootFD)
    }

    func entryExists(_ relativePath: String) -> Bool {
        (try? withLeaf(relativePath) { directoryFD, leaf in
            var info = stat()
            return fstatat(
                directoryFD,
                leaf,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        }) ?? false
    }

    func isRegularFile(_ relativePath: String) -> Bool {
        (try? withLeaf(relativePath) { directoryFD, leaf in
            var info = stat()
            guard fstatat(
                directoryFD,
                leaf,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                return false
            }
            return (info.st_mode & S_IFMT) == S_IFREG
                && info.st_nlink == 1
        }) ?? false
    }

    func isDirectory(_ relativePath: String) -> Bool {
        (try? withLeaf(relativePath) { directoryFD, leaf in
            var info = stat()
            guard fstatat(
                directoryFD,
                leaf,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                return false
            }
            return (info.st_mode & S_IFMT) == S_IFDIR
        }) ?? false
    }

    func read(_ relativePath: String, maximumBytes: Int) throws -> Data {
        try withOpenFile(relativePath) { fd, before in
            guard before.st_size >= 0,
                  before.st_size <= off_t(maximumBytes) else {
                throw SourceDataMigrationError.fileTooLarge(relativePath)
            }
            return try readExactly(
                fd,
                count: Int(before.st_size),
                relativePath: relativePath
            )
        }
    }

    func readTail(
        _ relativePath: String,
        maximumBytes: Int
    ) throws -> (data: Data, startsMidFile: Bool) {
        try withOpenFile(relativePath) { fd, before in
            guard before.st_size >= 0 else {
                throw SourceDataMigrationError.unsafeSourceEntry(relativePath)
            }
            let count = min(Int64(before.st_size), Int64(maximumBytes))
            let offset = before.st_size - off_t(count)
            guard lseek(fd, offset, SEEK_SET) == offset else {
                throw SourceDataMigrationError.unsafeSourceEntry(relativePath)
            }
            return (
                try readExactly(
                    fd,
                    count: Int(count),
                    relativePath: relativePath
                ),
                offset > 0
            )
        }
    }

    private func withOpenFile<Result>(
        _ relativePath: String,
        operation: (Int32, stat) throws -> Result
    ) throws -> Result {
        try withLeaf(relativePath) { directoryFD, leaf in
            let fd = openat(
                directoryFD,
                leaf,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard fd >= 0 else {
                throw SourceDataMigrationError.unsafeSourceEntry(relativePath)
            }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_nlink == 1 else {
                throw SourceDataMigrationError.unsafeSourceEntry(relativePath)
            }
            let result = try operation(fd, before)
            var after = stat()
            guard fstat(fd, &after) == 0,
                  sameStableFile(before, after) else {
                throw SourceDataMigrationError.sourceChanged(relativePath)
            }
            return result
        }
    }

    private func withLeaf<Result>(
        _ relativePath: String,
        operation: (Int32, String) throws -> Result
    ) throws -> Result {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
              }) else {
            throw SourceDataMigrationError.unsafeSourceEntry(relativePath)
        }
        var directoryFD = dup(rootFD)
        guard directoryFD >= 0 else {
            throw SourceDataMigrationError.unsafeSourceRoot
        }
        defer { close(directoryFD) }
        for component in components.dropLast() {
            let next = openat(
                directoryFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                throw SourceDataMigrationError.unsafeSourceEntry(relativePath)
            }
            close(directoryFD)
            directoryFD = next
        }
        return try operation(directoryFD, components.last!)
    }

    private func readExactly(
        _ fd: Int32,
        count: Int,
        relativePath: String
    ) throws -> Data {
        var data = Data(count: count)
        var total = 0
        let readSucceeded = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else {
                return count == 0
            }
            while total < count {
                let amount = Darwin.read(fd, base.advanced(by: total), count - total)
                if amount > 0 {
                    total += amount
                } else if amount < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard readSucceeded, total == count else {
            throw SourceDataMigrationError.sourceChanged(relativePath)
        }
        return data
    }
}
