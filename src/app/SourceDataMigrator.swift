import Darwin
import CoreFoundation
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

struct SourceInstallCandidate: Identifiable, Equatable {
    let rootURL: URL
    let availableItems: Set<MigrationItem>

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
        case .commitFailed:
            return "无法提交导入数据，原有数据已恢复。"
        case .rollbackFailed:
            return "导入回滚失败，请不要开启保护并查看日志。"
        }
    }
}

final class SourceDataMigrator {
    private static let configurationByteLimit = 1 * 1_024 * 1_024
    private static let ownerTemplateByteLimit = 64 * 1_024 * 1_024
    private static let preferencesByteLimit = 64 * 1_024
    private static let activityScanByteLimit = 4 * 1_024 * 1_024
    private static let activityRecordByteLimit = 256 * 1_024
    private static let activityLineLimit = 10_000

    private let fileManager: FileManager
    private let candidateRootURLs: [URL]?
    private let afterCommit: ((Int) throws -> Void)?

    init(
        fileManager: FileManager = .default,
        candidateRootURLs: [URL]? = nil,
        afterCommit: ((Int) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.candidateRootURLs = candidateRootURLs
        self.afterCommit = afterCommit
    }

    func discoverCandidates() -> [SourceInstallCandidate] {
        let roots = candidateRootURLs ?? legacyCandidateRoots()
        var seen = Set<String>()
        return roots.compactMap { root in
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
                availableItems: items
            )
        }
        .sorted { $0.rootURL.path < $1.rootURL.path }
    }

    func `import`(
        candidate: SourceInstallCandidate,
        destination: URL
    ) throws -> MigrationResult {
        let reader: SecureSourceReader
        do {
            reader = try SecureSourceReader(rootURL: candidate.rootURL)
        } catch {
            throw SourceDataMigrationError.unsafeSourceRoot
        }
        guard reader.isRegularFile("agent.py"),
              reader.isRegularFile(MigrationItem.configuration.sourcePath),
              reader.isDirectory("data") else {
            throw SourceDataMigrationError.unsafeSourceRoot
        }

        let destinationRoot = try validatedDestinationRoot(destination)
        let transactionID = "import-\(UUID().uuidString.lowercased())"
        let backupsRoot = destinationRoot.appendingPathComponent(
            "backups",
            isDirectory: true
        )
        let transactionRoot = backupsRoot.appendingPathComponent(
            transactionID,
            isDirectory: true
        )
        let stagingRoot = transactionRoot.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        let rollbackRoot = transactionRoot.appendingPathComponent(
            "rollback",
            isDirectory: true
        )
        var createdDestinationDirectories: [URL] = []
        var preserveTransactionForRecovery = false
        let backupsExisted = fileManager.fileExists(atPath: backupsRoot.path)

        do {
            try createSafeDirectory(
                backupsRoot,
                inside: destinationRoot,
                created: &createdDestinationDirectories
            )
            try fileManager.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: rollbackRoot,
                withIntermediateDirectories: true
            )

            let staged = try stageAndValidate(
                candidate: candidate,
                reader: reader,
                stagingRoot: stagingRoot
            )
            let journal = try prepareJournal(
                staged: staged,
                destinationRoot: destinationRoot,
                rollbackRoot: rollbackRoot,
                createdDirectories: &createdDestinationDirectories
            )
            try writeJournal(
                journal,
                to: transactionRoot.appendingPathComponent("journal.json")
            )

            var committedCount = 0
            do {
                try commit(
                    journal: journal,
                    transactionRoot: transactionRoot,
                    committedCount: &committedCount
                )
            } catch {
                do {
                    try rollback(
                        journal: Array(journal.prefix(committedCount))
                    )
                } catch {
                    preserveTransactionForRecovery = true
                    throw SourceDataMigrationError.rollbackFailed
                }
                try? fileManager.removeItem(at: transactionRoot)
                removeCreatedDirectoriesIfEmpty(
                    createdDestinationDirectories,
                    preserving: backupsExisted ? backupsRoot : nil
                )
                throw error
            }

            try? fileManager.removeItem(at: stagingRoot)
            return MigrationResult(
                importedItems: Set(staged.map(\.item)),
                backupURL: transactionRoot
            )
        } catch {
            if !preserveTransactionForRecovery,
               fileManager.fileExists(atPath: transactionRoot.path) {
                try? fileManager.removeItem(at: transactionRoot)
            }
            if !preserveTransactionForRecovery {
                removeCreatedDirectoriesIfEmpty(
                    createdDestinationDirectories,
                    preserving: backupsExisted ? backupsRoot : nil
                )
            }
            throw error
        }
    }

    private func stageAndValidate(
        candidate: SourceInstallCandidate,
        reader: SecureSourceReader,
        stagingRoot: URL
    ) throws -> [StagedMigrationFile] {
        var staged: [StagedMigrationFile] = []
        for item in MigrationItem.allCases where candidate.availableItems.contains(item) {
            let data: Data
            do {
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
                    guard Self.isValidOwnerTemplate(data) else {
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
            } catch let error as SourceDataMigrationError {
                throw error
            } catch {
                throw SourceDataMigrationError.unsafeSourceEntry(item.sourcePath)
            }

            let stageURL = stagingRoot.appendingPathComponent(
                item.destinationPath
            )
            try fileManager.createDirectory(
                at: stageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: stageURL, options: .atomic)
            staged.append(
                StagedMigrationFile(
                    item: item,
                    stageURL: stageURL,
                    relativeDestinationPath: item.destinationPath
                )
            )
        }
        return staged
    }

    private func prepareJournal(
        staged: [StagedMigrationFile],
        destinationRoot: URL,
        rollbackRoot: URL,
        createdDirectories: inout [URL]
    ) throws -> [MigrationJournalEntry] {
        var entries: [MigrationJournalEntry] = []
        for stagedFile in staged {
            let target = destinationRoot.appendingPathComponent(
                stagedFile.relativeDestinationPath
            )
            let parent = target.deletingLastPathComponent()
            try createSafeDirectory(
                parent,
                inside: destinationRoot,
                created: &createdDirectories
            )
            let existed = fileManager.fileExists(atPath: target.path)
            var backupURL: URL?
            if existed {
                guard isRegularNonSymlink(target) else {
                    throw SourceDataMigrationError.unsafeDestination(target.path)
                }
                let backup = rollbackRoot.appendingPathComponent(
                    stagedFile.relativeDestinationPath
                )
                try fileManager.createDirectory(
                    at: backup.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: target, to: backup)
                backupURL = backup
            }
            entries.append(
                MigrationJournalEntry(
                    item: stagedFile.item,
                    stageURL: stagedFile.stageURL,
                    targetURL: target,
                    backupURL: backupURL,
                    existed: existed
                )
            )
        }
        return entries
    }

    private func commit(
        journal: [MigrationJournalEntry],
        transactionRoot: URL,
        committedCount: inout Int
    ) throws {
        for entry in journal {
            guard isRegularNonSymlink(entry.stageURL),
                  isSafeTarget(entry.targetURL) else {
                throw SourceDataMigrationError.commitFailed
            }
            guard rename(entry.stageURL.path, entry.targetURL.path) == 0 else {
                throw SourceDataMigrationError.commitFailed
            }
            committedCount += 1
            try writeJournal(
                journal,
                committedCount: committedCount,
                to: transactionRoot.appendingPathComponent("journal.json")
            )
            try afterCommit?(committedCount)
        }
    }

    private func rollback(journal: [MigrationJournalEntry]) throws {
        var rollbackFailed = false
        for entry in journal.reversed() {
            if let backup = entry.backupURL {
                let temporary = entry.targetURL.deletingLastPathComponent()
                    .appendingPathComponent(".rollback-\(UUID().uuidString)")
                do {
                    try fileManager.copyItem(at: backup, to: temporary)
                    guard rename(temporary.path, entry.targetURL.path) == 0 else {
                        try? fileManager.removeItem(at: temporary)
                        rollbackFailed = true
                        continue
                    }
                } catch {
                    try? fileManager.removeItem(at: temporary)
                    rollbackFailed = true
                }
            } else if fileManager.fileExists(atPath: entry.targetURL.path) {
                do {
                    try fileManager.removeItem(at: entry.targetURL)
                } catch {
                    rollbackFailed = true
                }
            }
        }
        if rollbackFailed {
            throw SourceDataMigrationError.rollbackFailed
        }
    }

    private func writeJournal(
        _ entries: [MigrationJournalEntry],
        committedCount: Int = 0,
        to url: URL
    ) throws {
        let payload: [String: Any] = [
            "schema_version": 1,
            "committed_count": committedCount,
            "entries": entries.map {
                [
                    "item": $0.item.rawValue,
                    "target": $0.targetURL.path,
                    "backup": $0.backupURL?.path as Any,
                    "existed": $0.existed,
                ]
            },
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func validatedDestinationRoot(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard isDirectoryNonSymlink(standardized) else {
            throw SourceDataMigrationError.unsafeDestination(standardized.path)
        }
        return standardized
    }

    private func createSafeDirectory(
        _ url: URL,
        inside root: URL,
        created: inout [URL]
    ) throws {
        guard isDescendant(url, of: root) else {
            throw SourceDataMigrationError.unsafeDestination(url.path)
        }
        if fileManager.fileExists(atPath: url.path) {
            guard isDirectoryNonSymlink(url) else {
                throw SourceDataMigrationError.unsafeDestination(url.path)
            }
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != root.path {
            try createSafeDirectory(parent, inside: root, created: &created)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        created.append(url)
    }

    private func isSafeTarget(_ url: URL) -> Bool {
        !fileManager.fileExists(atPath: url.path) || isRegularNonSymlink(url)
    }

    private func isRegularNonSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    private func isDirectoryNonSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count > rootComponents.count
            && zip(rootComponents, candidateComponents).allSatisfy(==)
    }

    private func removeCreatedDirectoriesIfEmpty(
        _ directories: [URL],
        preserving: URL?
    ) {
        for directory in directories.reversed()
            where directory.standardizedFileURL != preserving?.standardizedFileURL {
            guard let contents = try? fileManager.contentsOfDirectory(
                atPath: directory.path
            ), contents.isEmpty else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func legacyCandidateRoots() -> [URL] {
        guard let home = fileManager.homeDirectoryForCurrentUser as URL? else {
            return []
        }
        let launchAgents = home.appendingPathComponent(
            "Library/LaunchAgents",
            isDirectory: true
        )
        let plistNames = [
            "com.wuyi.mac-face-lock-agent.plist",
            "com.wuyi.mac-face-lock-release.plist",
            "com.wuyi.mac-face-lock-status.plist",
        ]
        var roots: [URL] = []
        for name in plistNames {
            let plistURL = launchAgents.appendingPathComponent(name)
            var plistInfo = stat()
            guard lstat(plistURL.path, &plistInfo) == 0,
                  (plistInfo.st_mode & S_IFMT) == S_IFREG,
                  plistInfo.st_size >= 0,
                  plistInfo.st_size <= 1 * 1_024 * 1_024,
                  let data = try? Data(contentsOf: plistURL),
                  data.count == Int(plistInfo.st_size),
                  let object = try? PropertyListSerialization.propertyList(
                      from: data,
                      options: [],
                      format: nil
                  ),
                  let dictionary = object as? [String: Any],
                  let arguments = dictionary["ProgramArguments"] as? [String] else {
                continue
            }
            for argument in arguments where argument.hasPrefix("/") {
                let url = URL(fileURLWithPath: argument).standardizedFileURL
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    roots.append(url)
                } else if ["agent.py", "run-agent.sh"].contains(url.lastPathComponent) {
                    roots.append(url.deletingLastPathComponent())
                }
            }
        }
        return roots
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

    private static func isValidOwnerTemplate(_ data: Data) -> Bool {
        guard data.count >= 10,
              data.count <= ownerTemplateByteLimit,
              Array(data.prefix(6)) == [0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59],
              data[7] == 0 else {
            return false
        }
        let major = data[6]
        let headerStart: Int
        let headerLength: Int
        if major == 1 {
            headerStart = 10
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
        } else if (major == 2 || major == 3), data.count >= 12 {
            headerStart = 12
            let length = UInt32(data[8])
                | (UInt32(data[9]) << 8)
                | (UInt32(data[10]) << 16)
                | (UInt32(data[11]) << 24)
            guard let converted = Int(exactly: length) else {
                return false
            }
            headerLength = converted
        } else {
            return false
        }
        let payloadStart = headerStart.addingReportingOverflow(headerLength)
        guard !payloadStart.overflow,
              headerLength > 0,
              headerLength <= 10_000,
              payloadStart.partialValue <= data.count,
              let header = String(
                  data: data[headerStart..<payloadStart.partialValue],
                  encoding: .ascii
              ),
              let expression = try? NSRegularExpression(
                  pattern: #"^\{\s*['"]descr['"]\s*:\s*['"]<f4['"]\s*,\s*['"]fortran_order['"]\s*:\s*False\s*,\s*['"]shape['"]\s*:\s*\(\s*([0-9]+)\s*,\s*9216\s*,?\s*\)\s*,?\s*\}\s*$"#
              ),
              let match = expression.firstMatch(
                  in: header,
                  range: NSRange(header.startIndex..., in: header)
              ),
              match.range.location != NSNotFound,
              let rowsRange = Range(match.range(at: 1), in: header),
              let rows = Int(header[rowsRange]),
              rows >= 2 else {
            return false
        }
        let valueCount = rows.multipliedReportingOverflow(by: 9_216)
        let payloadBytes = valueCount.partialValue.multipliedReportingOverflow(by: 4)
        let payloadEnd = payloadStart.partialValue.addingReportingOverflow(
            payloadBytes.partialValue
        )
        guard !valueCount.overflow, !payloadBytes.overflow, !payloadEnd.overflow,
              payloadEnd.partialValue == data.count else {
            return false
        }
        var offset = payloadStart.partialValue
        while offset < data.count {
            let bits = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            guard Float(bitPattern: bits).isFinite else {
                return false
            }
            offset += 4
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

private struct StagedMigrationFile {
    let item: MigrationItem
    let stageURL: URL
    let relativeDestinationPath: String
}

private struct MigrationJournalEntry {
    let item: MigrationItem
    let stageURL: URL
    let targetURL: URL
    let backupURL: URL?
    let existed: Bool
}

private final class SecureSourceReader {
    private let rootFD: Int32

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
                  (before.st_mode & S_IFMT) == S_IFREG else {
                throw SourceDataMigrationError.unsafeSourceEntry(relativePath)
            }
            let result = try operation(fd, before)
            var after = stat()
            guard fstat(fd, &after) == 0,
                  before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
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
