import Darwin
import Foundation

struct SecureFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct SecureTreeBudget: Equatable, Sendable {
    let maximumEntries: Int
    let maximumLogicalBytes: UInt64

    static let legacyCleanup = SecureTreeBudget(
        maximumEntries: 50_000,
        maximumLogicalBytes: UInt64(20) * 1_024 * 1_024 * 1_024
    )
}

struct SecureTreeEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case directory
    }

    let relativePath: String
    let identity: SecureFileIdentity
    let kind: Kind
    let fileVersion: SecureRegularFileVersion?
}

struct SecureRegularFileVersion: Codable, Equatable, Sendable {
    let logicalSize: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

private struct SecureFileFingerprint: Equatable {
    let identity: SecureFileIdentity
    let owner: uid_t
    let mode: mode_t
    let linkCount: UInt64
    let version: SecureRegularFileVersion
}

private struct SecureDirectoryVersion: Equatable {
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

private struct SecureDirectoryBinding: Equatable {
    let identity: SecureFileIdentity
    let version: SecureDirectoryVersion?
}

struct SecureTreeManifest: Codable, Equatable, Sendable {
    let rootIdentity: SecureFileIdentity
    let entriesDeepestFirst: [SecureTreeEntry]
}

struct SecureTreeTombstone: Codable, Equatable, Sendable {
    let originalRelativePath: String
    let tombstoneRelativePath: String
    let identity: SecureFileIdentity
    let kind: SecureTreeEntry.Kind
    let purges: [SecureTreePurge]
}

struct SecureTreePurge: Codable, Equatable, Sendable {
    let originalRelativePath: String
    let tombstoneRelativePath: String
    let purgeRelativePath: String
    let identity: SecureFileIdentity
    let kind: SecureTreeEntry.Kind
    let fileVersion: SecureRegularFileVersion?
}

enum SecureFileTreeError: Error, Equatable {
    case invalidRoot(String)
    case invalidRelativePath(String)
    case ownerMismatch(String)
    case symbolicLink(String)
    case hardLink(String)
    case specialFile(String)
    case entryBudgetExceeded
    case byteBudgetExceeded
    case identityChanged(String)
    case systemCall(String, String, Int32)
}

enum SecureRemovalFlags {
    // These Darwin flags first appear in the macOS 26 SDK and kernel. Keep
    // older supported systems on the portable unlinkat flag set.
    private static let noDeleteBusy: Int32 = 0x4000
    private static let unique: Int32 = 0x8000

    static func unlinkFlags(
        kind: SecureTreeEntry.Kind,
        operatingSystemMajorVersion: Int =
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Int32 {
        var flags: Int32 = kind == .directory ? AT_REMOVEDIR : 0
        guard operatingSystemMajorVersion >= 26 else {
            return flags
        }
        flags |= noDeleteBusy
        if kind == .file {
            flags |= unique
        }
        return flags
    }
}

private enum SecurePurgeState: Equatable {
    case absent
    case original
    case tombstone
    case purge
}

final class SecureFileTree {
    let rootIdentity: SecureFileIdentity

    private let ancestorFD: Int32
    private let rootFD: Int32
    private let rootComponents: [String]
    private let rootPath: String
    private let requiredOwner: uid_t

    init(
        rootURL: URL,
        requiredAncestorURL: URL,
        requiredOwner: uid_t
    ) throws {
        let rootPath = rootURL.path
        let ancestorPath = requiredAncestorURL.path
        guard
            rootURL.isFileURL,
            requiredAncestorURL.isFileURL,
            rootPath.hasPrefix("/"),
            ancestorPath.hasPrefix("/"),
            rootURL.standardizedFileURL.path == rootPath,
            requiredAncestorURL.standardizedFileURL.path == ancestorPath,
            rootPath != ancestorPath,
            rootPath.hasPrefix(ancestorPath == "/" ? "/" : ancestorPath + "/")
        else {
            throw SecureFileTreeError.invalidRoot(rootPath)
        }

        let ancestorFD = Darwin.open(
            ancestorPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard ancestorFD >= 0 else {
            throw SecureFileTreeError.systemCall("open", ancestorPath, errno)
        }
        var keepAncestorFD = false
        defer {
            if !keepAncestorFD {
                Darwin.close(ancestorFD)
            }
        }

        var ancestorStat = stat()
        guard fstat(ancestorFD, &ancestorStat) == 0 else {
            throw SecureFileTreeError.systemCall("fstat", ancestorPath, errno)
        }
        guard ancestorStat.st_mode & S_IFMT == S_IFDIR else {
            throw SecureFileTreeError.invalidRoot(ancestorPath)
        }

        let relativeRoot = String(
            rootPath.dropFirst(ancestorPath == "/" ? 1 : ancestorPath.count + 1)
        )
        let components = relativeRoot.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard
            !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw SecureFileTreeError.invalidRoot(rootPath)
        }

        var currentFD = dup(ancestorFD)
        guard currentFD >= 0 else {
            throw SecureFileTreeError.systemCall("dup", ancestorPath, errno)
        }
        var keepCurrentFD = false
        defer {
            if !keepCurrentFD {
                Darwin.close(currentFD)
            }
        }

        var traversed: [String] = []
        var resolvedIdentity: SecureFileIdentity?
        for (index, component) in components.enumerated() {
            traversed.append(component)
            let relativePath = traversed.joined(separator: "/")
            var entryStat = stat()
            guard fstatat(currentFD, component, &entryStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SecureFileTreeError.systemCall("fstatat", relativePath, errno)
            }
            let displayPath = index == components.count - 1 ? rootPath : relativePath
            let (identity, kind) = try Self.checkedIdentity(
                entryStat,
                path: displayPath,
                requiredOwner: requiredOwner
            )
            guard kind == .directory else {
                throw SecureFileTreeError.invalidRoot(rootPath)
            }

            let nextFD = openat(
                currentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard nextFD >= 0 else {
                if errno == ELOOP {
                    throw SecureFileTreeError.symbolicLink(relativePath)
                }
                throw SecureFileTreeError.systemCall("openat", relativePath, errno)
            }
            var openedStat = stat()
            guard fstat(nextFD, &openedStat) == 0 else {
                let savedErrno = errno
                Darwin.close(nextFD)
                throw SecureFileTreeError.systemCall("fstat", relativePath, savedErrno)
            }
            let openedIdentity = SecureFileIdentity(
                device: UInt64(openedStat.st_dev),
                inode: UInt64(openedStat.st_ino)
            )
            guard openedIdentity == identity else {
                Darwin.close(nextFD)
                throw SecureFileTreeError.identityChanged(relativePath)
            }
            Darwin.close(currentFD)
            currentFD = nextFD
            resolvedIdentity = identity
        }

        guard let resolvedIdentity else {
            throw SecureFileTreeError.invalidRoot(rootPath)
        }
        self.ancestorFD = ancestorFD
        self.rootFD = currentFD
        self.rootComponents = components
        self.rootPath = rootPath
        self.requiredOwner = requiredOwner
        self.rootIdentity = resolvedIdentity
        keepAncestorFD = true
        keepCurrentFD = true
    }

    deinit {
        Darwin.close(ancestorFD)
        Darwin.close(rootFD)
    }

    func readRegularFile(_ relativePath: String, maximumBytes: Int) throws -> Data {
        let components = try validatedComponents(relativePath)
        guard maximumBytes >= 0 else {
            throw SecureFileTreeError.byteBudgetExceeded
        }
        let (parentFD, name) = try openParent(components, path: relativePath)
        defer { Darwin.close(parentFD) }

        var entryStat = stat()
        guard fstatat(parentFD, name, &entryStat, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecureFileTreeError.systemCall("fstatat", relativePath, errno)
        }
        let (identity, kind) = try Self.checkedIdentity(
            entryStat,
            path: relativePath,
            requiredOwner: requiredOwner
        )
        guard kind == .file else {
            throw SecureFileTreeError.specialFile(relativePath)
        }
        guard entryStat.st_size >= 0, UInt64(entryStat.st_size) <= UInt64(maximumBytes) else {
            throw SecureFileTreeError.byteBudgetExceeded
        }

        let fileFD = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fileFD >= 0 else {
            if errno == ELOOP {
                throw SecureFileTreeError.symbolicLink(relativePath)
            }
            throw SecureFileTreeError.systemCall("openat", relativePath, errno)
        }
        defer { Darwin.close(fileFD) }

        var openedStat = stat()
        guard fstat(fileFD, &openedStat) == 0 else {
            throw SecureFileTreeError.systemCall("fstat", relativePath, errno)
        }
        let openedIdentity = SecureFileIdentity(
            device: UInt64(openedStat.st_dev),
            inode: UInt64(openedStat.st_ino)
        )
        guard openedIdentity == identity else {
            throw SecureFileTreeError.identityChanged(relativePath)
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(fileFD, &buffer, buffer.count)
            if count == 0 {
                return result
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw SecureFileTreeError.systemCall("read", relativePath, errno)
            }
            let (newCount, overflow) = result.count.addingReportingOverflow(Int(count))
            guard !overflow, newCount <= maximumBytes else {
                throw SecureFileTreeError.byteBudgetExceeded
            }
            result.append(contentsOf: buffer.prefix(Int(count)))
        }
    }

    func loadValidatedFile(
        _ relativePath: String,
        maximumBytes: Int,
        requiredMode: mode_t,
        afterOpen: (() throws -> Void)? = nil
    ) throws -> Data {
        let name = try validatedSingleComponent(relativePath)
        guard maximumBytes >= 0 else {
            throw SecureFileTreeError.byteBudgetExceeded
        }
        try requireStableRoot()
        let bindingBefore = try capturePathBinding(includeRootVersion: true)

        var pathStat = stat()
        guard fstatat(rootFD, name, &pathStat, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecureFileTreeError.systemCall("fstatat", relativePath, errno)
        }
        let initial = try validatedFileFingerprint(
            pathStat,
            path: relativePath,
            maximumBytes: maximumBytes,
            requiredMode: requiredMode
        )

        let fileDescriptor = openat(
            rootFD,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else {
            if errno == ELOOP {
                throw SecureFileTreeError.symbolicLink(relativePath)
            }
            throw SecureFileTreeError.systemCall("openat", relativePath, errno)
        }
        defer { Darwin.close(fileDescriptor) }

        var openedStat = stat()
        guard fstat(fileDescriptor, &openedStat) == 0 else {
            throw SecureFileTreeError.systemCall("fstat", relativePath, errno)
        }
        guard try validatedFileFingerprint(
            openedStat,
            path: relativePath,
            maximumBytes: maximumBytes,
            requiredMode: requiredMode
        ) == initial else {
            throw SecureFileTreeError.identityChanged(relativePath)
        }

        try afterOpen?()
        let data = try readAll(
            fileDescriptor,
            path: relativePath,
            maximumBytes: maximumBytes
        )

        var finalOpenedStat = stat()
        guard fstat(fileDescriptor, &finalOpenedStat) == 0 else {
            throw SecureFileTreeError.systemCall("fstat", relativePath, errno)
        }
        guard try validatedFileFingerprint(
            finalOpenedStat,
            path: relativePath,
            maximumBytes: maximumBytes,
            requiredMode: requiredMode
        ) == initial else {
            throw SecureFileTreeError.identityChanged(relativePath)
        }

        var finalPathStat = stat()
        guard fstatat(
            rootFD,
            name,
            &finalPathStat,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                throw SecureFileTreeError.identityChanged(relativePath)
            }
            throw SecureFileTreeError.systemCall("fstatat", relativePath, errno)
        }
        guard try validatedFileFingerprint(
            finalPathStat,
            path: relativePath,
            maximumBytes: maximumBytes,
            requiredMode: requiredMode
        ) == initial else {
            throw SecureFileTreeError.identityChanged(relativePath)
        }
        let bindingAfter = try capturePathBinding(includeRootVersion: true)
        guard bindingAfter == bindingBefore else {
            throw SecureFileTreeError.identityChanged(relativePath)
        }
        try requireStableRoot()
        return data
    }

    func replaceFileAtomically(
        _ relativePath: String,
        temporaryName: String,
        data: Data,
        maximumBytes: Int,
        mode: mode_t,
        beforeRename: (() throws -> Void)? = nil
    ) throws {
        let name = try validatedSingleComponent(relativePath)
        let temporary = try validatedSingleComponent(temporaryName)
        guard name != temporary else {
            throw SecureFileTreeError.invalidRelativePath(temporaryName)
        }
        guard maximumBytes >= 0, data.count <= maximumBytes else {
            throw SecureFileTreeError.byteBudgetExceeded
        }
        try requireStableRoot()
        let bindingBefore = try capturePathBinding(includeRootVersion: false)
        let initialDestination = try fileFingerprintIfPresent(
            name,
            path: relativePath,
            maximumBytes: maximumBytes,
            requiredMode: mode
        )

        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let fileDescriptor = openat(rootFD, temporary, flags, mode)
        guard fileDescriptor >= 0 else {
            throw SecureFileTreeError.systemCall("openat", temporaryName, errno)
        }
        var published = false
        defer {
            Darwin.close(fileDescriptor)
            if !published {
                _ = unlinkat(rootFD, temporary, 0)
            }
        }

        guard fchmod(fileDescriptor, mode) == 0 else {
            throw SecureFileTreeError.systemCall("fchmod", temporaryName, errno)
        }
        var initialTemporaryStat = stat()
        guard fstat(fileDescriptor, &initialTemporaryStat) == 0 else {
            throw SecureFileTreeError.systemCall("fstat", temporaryName, errno)
        }
        let initialTemporary = try validatedFileFingerprint(
            initialTemporaryStat,
            path: temporaryName,
            maximumBytes: maximumBytes,
            requiredMode: mode
        )

        try writeAll(fileDescriptor, data: data, path: temporaryName)
        guard fsync(fileDescriptor) == 0 else {
            throw SecureFileTreeError.systemCall("fsync", temporaryName, errno)
        }
        var writtenTemporaryStat = stat()
        guard fstat(fileDescriptor, &writtenTemporaryStat) == 0 else {
            throw SecureFileTreeError.systemCall("fstat", temporaryName, errno)
        }
        let writtenTemporary = try validatedFileFingerprint(
            writtenTemporaryStat,
            path: temporaryName,
            maximumBytes: maximumBytes,
            requiredMode: mode
        )
        guard
            writtenTemporary.identity == initialTemporary.identity,
            writtenTemporary.version.logicalSize == UInt64(data.count)
        else {
            throw SecureFileTreeError.identityChanged(temporaryName)
        }

        let publicationBinding = try capturePathBinding(
            includeRootVersion: true
        )
        try beforeRename?()
        try requireStableRoot()
        guard try capturePathBinding(includeRootVersion: false) == bindingBefore else {
            throw SecureFileTreeError.identityChanged(rootPath)
        }
        guard try fileFingerprintIfPresent(
            temporary,
            path: temporaryName,
            maximumBytes: maximumBytes,
            requiredMode: mode
        ) == writtenTemporary else {
            throw SecureFileTreeError.identityChanged(temporaryName)
        }
        guard try fileFingerprintIfPresent(
            name,
            path: relativePath,
            maximumBytes: maximumBytes,
            requiredMode: mode
        ) == initialDestination else {
            throw SecureFileTreeError.identityChanged(relativePath)
        }
        guard try capturePathBinding(
            includeRootVersion: true
        ) == publicationBinding else {
            throw SecureFileTreeError.identityChanged(rootPath)
        }

        guard renameat(rootFD, temporary, rootFD, name) == 0 else {
            throw SecureFileTreeError.systemCall("renameat", relativePath, errno)
        }
        published = true
        guard fsync(rootFD) == 0 else {
            throw SecureFileTreeError.systemCall("fsync", rootPath, errno)
        }
        try requireStableRoot()
        guard try capturePathBinding(includeRootVersion: false) == bindingBefore else {
            throw SecureFileTreeError.identityChanged(rootPath)
        }

        let destination = try fileFingerprintIfPresent(
            name,
            path: relativePath,
            maximumBytes: maximumBytes,
            requiredMode: mode
        )
        guard
            let destination,
            destination.identity == writtenTemporary.identity,
            destination.owner == writtenTemporary.owner,
            destination.mode == writtenTemporary.mode,
            destination.linkCount == writtenTemporary.linkCount,
            destination.version.logicalSize
                == writtenTemporary.version.logicalSize,
            destination.version.modificationSeconds
                == writtenTemporary.version.modificationSeconds,
            destination.version.modificationNanoseconds
                == writtenTemporary.version.modificationNanoseconds
        else {
            throw SecureFileTreeError.identityChanged(relativePath)
        }
        var removedTemporary = stat()
        guard fstatat(
            rootFD,
            temporary,
            &removedTemporary,
            AT_SYMLINK_NOFOLLOW
        ) != 0, errno == ENOENT else {
            throw SecureFileTreeError.identityChanged(temporaryName)
        }
        let verified = try loadValidatedFile(
            relativePath,
            maximumBytes: maximumBytes,
            requiredMode: mode
        )
        guard verified == data else {
            throw SecureFileTreeError.identityChanged(relativePath)
        }
    }

    func preflight(
        relativeTargets: [String],
        budget: SecureTreeBudget
    ) throws -> SecureTreeManifest {
        guard budget.maximumEntries >= 0 else {
            throw SecureFileTreeError.entryBudgetExceeded
        }
        try requireStableRoot()

        var validatedTargets: [[String]] = []
        var targetSet = Set<String>()
        for target in relativeTargets {
            let components = try validatedComponents(target)
            let normalized = components.joined(separator: "/")
            guard targetSet.insert(normalized).inserted else {
                throw SecureFileTreeError.invalidRelativePath(target)
            }
            validatedTargets.append(components)
        }

        var entriesByPath: [String: SecureTreeEntry] = [:]
        var logicalBytes: UInt64 = 0
        for components in validatedTargets {
            let target = components.joined(separator: "/")
            let (parentFD, name) = try openParent(
                components,
                path: target,
                missingIsAllowed: true
            )
            guard parentFD >= 0 else {
                continue
            }
            do {
                defer { Darwin.close(parentFD) }
                var targetStat = stat()
                guard fstatat(parentFD, name, &targetStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT {
                        continue
                    }
                    throw SecureFileTreeError.systemCall("fstatat", target, errno)
                }
                try collectEntry(
                    parentFD: parentFD,
                    name: name,
                    relativePath: target,
                    initialStat: targetStat,
                    budget: budget,
                    entriesByPath: &entriesByPath,
                    logicalBytes: &logicalBytes
                )
            }
        }

        try requireStableRoot()
        let entries = entriesByPath.values.sorted { left, right in
            let leftDepth = left.relativePath.split(separator: "/").count
            let rightDepth = right.relativePath.split(separator: "/").count
            if leftDepth != rightDepth {
                return leftDepth > rightDepth
            }
            return left.relativePath < right.relativePath
        }
        return SecureTreeManifest(
            rootIdentity: rootIdentity,
            entriesDeepestFirst: entries
        )
    }

    func remove(_ manifest: SecureTreeManifest) throws {
        let roots = manifest.entriesDeepestFirst.filter { entry in
            !manifest.entriesDeepestFirst.contains { possibleParent in
                possibleParent.relativePath != entry.relativePath
                    && entry.relativePath.hasPrefix(
                        possibleParent.relativePath + "/"
                    )
            }
        }.map(\.relativePath)
        let tombstones = try makeTombstones(
            manifest: manifest,
            relativeTargets: roots
        )
        try remove(manifest, tombstones: tombstones)
    }

    func makeTombstones(
        manifest: SecureTreeManifest,
        relativeTargets: [String],
        nonce: () -> String = { UUID().uuidString.lowercased() },
        purgeNonce: () -> String = { UUID().uuidString.lowercased() }
    ) throws -> [SecureTreeTombstone] {
        guard manifest.rootIdentity == rootIdentity else {
            throw SecureFileTreeError.identityChanged(rootPath)
        }
        let entries = Dictionary(
            uniqueKeysWithValues: manifest.entriesDeepestFirst.map {
                ($0.relativePath, $0)
            }
        )
        var allPurgePaths = Set<String>()
        return try relativeTargets.compactMap { target in
            _ = try validatedComponents(target)
            guard let entry = entries[target] else {
                return nil
            }
            let components = try validatedComponents(target)
            let parent = components.dropLast().joined(separator: "/")
            let privateName = ".mac-face-lock-delete-\(nonce())"
            let tombstonePath = parent.isEmpty
                ? privateName
                : parent + "/" + privateName
            let purges = try manifest.entriesDeepestFirst.compactMap {
                manifestEntry -> SecureTreePurge? in
                guard manifestEntry.relativePath == target
                        || manifestEntry.relativePath.hasPrefix(target + "/") else {
                    return nil
                }
                let suffix = String(
                    manifestEntry.relativePath.dropFirst(target.count)
                )
                let movedPath = tombstonePath + suffix
                let movedComponents = try validatedComponents(movedPath)
                let movedParent = movedComponents.dropLast().joined(separator: "/")
                let purgeName = ".mac-face-lock-purge-\(purgeNonce())"
                _ = try validatedSingleComponent(purgeName)
                let purgePath = movedParent.isEmpty
                    ? purgeName
                    : movedParent + "/" + purgeName
                guard allPurgePaths.insert(purgePath).inserted else {
                    throw SecureFileTreeError.invalidRelativePath(purgePath)
                }
                return SecureTreePurge(
                    originalRelativePath: manifestEntry.relativePath,
                    tombstoneRelativePath: movedPath,
                    purgeRelativePath: purgePath,
                    identity: manifestEntry.identity,
                    kind: manifestEntry.kind,
                    fileVersion: manifestEntry.fileVersion
                )
            }
            return SecureTreeTombstone(
                originalRelativePath: target,
                tombstoneRelativePath: tombstonePath,
                identity: entry.identity,
                kind: entry.kind,
                purges: purges
            )
        }
    }

    func remove(
        _ manifest: SecureTreeManifest,
        tombstones: [SecureTreeTombstone],
        beforeRename: ((SecureTreeTombstone) throws -> Void)? = nil,
        afterRename: ((SecureTreeTombstone) throws -> Void)? = nil,
        beforeFinalRemoval: ((SecureTreeEntry) throws -> Void)? = nil,
        afterFinalRename: ((SecureTreePurge) throws -> Void)? = nil
    ) throws {
        guard manifest.rootIdentity == rootIdentity else {
            throw SecureFileTreeError.identityChanged(rootPath)
        }
        try requireStableRoot()
        let entries = Dictionary(
            uniqueKeysWithValues: manifest.entriesDeepestFirst.map {
                ($0.relativePath, $0)
            }
        )
        for tombstone in tombstones {
            guard let rootEntry = entries[tombstone.originalRelativePath],
                  rootEntry.identity == tombstone.identity,
                  rootEntry.kind == tombstone.kind else {
                throw SecureFileTreeError.identityChanged(
                    tombstone.originalRelativePath
                )
            }
            try moveToTombstone(
                tombstone,
                entry: rootEntry,
                beforeRename: beforeRename,
                afterRename: afterRename
            )
            try deleteMovedTree(
                manifest: manifest,
                tombstone: tombstone,
                beforeFinalRemoval: beforeFinalRemoval,
                afterFinalRename: afterFinalRename
            )
        }
        try requireStableRoot()
    }

    func recoverTombstones(
        _ tombstones: [SecureTreeTombstone],
        budget: SecureTreeBudget,
        beforeRename: ((SecureTreeTombstone) throws -> Void)? = nil,
        afterRename: ((SecureTreeTombstone) throws -> Void)? = nil,
        beforeFinalRemoval: ((SecureTreeEntry) throws -> Void)? = nil,
        afterFinalRename: ((SecureTreePurge) throws -> Void)? = nil
    ) throws {
        try validateTombstoneStates(tombstones, budget: budget)
        for tombstone in tombstones {
            let rootPurge = tombstone.purges.first {
                $0.originalRelativePath == tombstone.originalRelativePath
            }
            guard let rootPurge else {
                throw SecureFileTreeError.invalidRelativePath(
                    tombstone.originalRelativePath
                )
            }
            if try validatedPurgeEntryIfPresent(
                rootPurge,
                at: rootPurge.originalRelativePath,
                allowRenameCtimeChange: false
            ) != nil {
                try moveToTombstone(
                    tombstone,
                    entry: secureEntry(
                        from: rootPurge,
                        relativePath: rootPurge.originalRelativePath
                    ),
                    beforeRename: beforeRename,
                    afterRename: afterRename
                )
            }
            try validateMutuallyExclusivePurgeStates(tombstone)
            for purge in tombstone.purges.sorted(
                by: purgeDeletionOrder
            ) {
                let state = try purgeState(purge)
                switch state {
                case .absent:
                    continue
                case .original:
                    throw SecureFileTreeError.identityChanged(
                        purge.originalRelativePath
                    )
                case .tombstone:
                    try removeEntryAtPath(
                        purge.tombstoneRelativePath,
                        purge: purge,
                        beforeFinalRemoval: beforeFinalRemoval,
                        afterFinalRename: afterFinalRename
                    )
                case .purge:
                    try removePersistedPurge(purge)
                }
            }
            try validateMutuallyExclusivePurgeStates(tombstone)
        }
        try requireStableRoot()
    }

    func validateTombstoneStates(
        _ tombstones: [SecureTreeTombstone],
        budget: SecureTreeBudget
    ) throws {
        try requireStableRoot()
        var purgeCount = 0
        for tombstone in tombstones {
            let (nextCount, overflow) = purgeCount.addingReportingOverflow(
                tombstone.purges.count
            )
            guard !overflow, nextCount <= budget.maximumEntries else {
                throw SecureFileTreeError.entryBudgetExceeded
            }
            purgeCount = nextCount
            try validateTombstoneDefinition(tombstone)
            try validateMutuallyExclusivePurgeStates(tombstone)
        }
        try requireStableRoot()
    }

    private func validateTombstoneDefinition(
        _ tombstone: SecureTreeTombstone
    ) throws {
        let originalRoot = try validatedComponents(
            tombstone.originalRelativePath
        )
        let movedRoot = try validatedComponents(
            tombstone.tombstoneRelativePath
        )
        guard originalRoot.dropLast() == movedRoot.dropLast(),
              movedRoot.last?.hasPrefix(".mac-face-lock-delete-") == true,
              !tombstone.purges.isEmpty else {
            throw SecureFileTreeError.invalidRelativePath(
                tombstone.tombstoneRelativePath
            )
        }
        var originals = Set<String>()
        var movedPaths = Set<String>()
        var purgePaths = Set<String>()
        var rootRecord: SecureTreePurge?
        for purge in tombstone.purges {
            let original = try validatedComponents(
                purge.originalRelativePath
            )
            let moved = try validatedComponents(
                purge.tombstoneRelativePath
            )
            let final = try validatedComponents(
                purge.purgeRelativePath
            )
            guard purge.originalRelativePath == tombstone.originalRelativePath
                    || purge.originalRelativePath.hasPrefix(
                        tombstone.originalRelativePath + "/"
                    ),
                  original.dropFirst(originalRoot.count)
                    == moved.dropFirst(movedRoot.count),
                  Array(moved.prefix(movedRoot.count)) == movedRoot,
                  moved.dropLast() == final.dropLast(),
                  final.last?.hasPrefix(".mac-face-lock-purge-") == true,
                  final.last != ".mac-face-lock-purge-",
                  originals.insert(purge.originalRelativePath).inserted,
                  movedPaths.insert(purge.tombstoneRelativePath).inserted,
                  purgePaths.insert(purge.purgeRelativePath).inserted,
                  (purge.kind == .file) == (purge.fileVersion != nil)
            else {
                throw SecureFileTreeError.invalidRelativePath(
                    purge.purgeRelativePath
                )
            }
            if purge.originalRelativePath == tombstone.originalRelativePath {
                rootRecord = purge
            }
        }
        guard let rootRecord,
              rootRecord.tombstoneRelativePath
                == tombstone.tombstoneRelativePath,
              rootRecord.identity == tombstone.identity,
              rootRecord.kind == tombstone.kind else {
            throw SecureFileTreeError.invalidRelativePath(
                tombstone.originalRelativePath
            )
        }
    }

    private func secureEntry(
        from purge: SecureTreePurge,
        relativePath: String
    ) -> SecureTreeEntry {
        SecureTreeEntry(
            relativePath: relativePath,
            identity: purge.identity,
            kind: purge.kind,
            fileVersion: purge.fileVersion
        )
    }

    private func validatedPurgeEntryIfPresent(
        _ purge: SecureTreePurge,
        at relativePath: String,
        allowRenameCtimeChange: Bool
    ) throws -> SecureTreeEntry? {
        let components = try validatedComponents(relativePath)
        let (parentFD, name) = try openParent(
            components,
            path: relativePath,
            missingIsAllowed: true
        )
        guard parentFD >= 0 else {
            return nil
        }
        defer { Darwin.close(parentFD) }
        var current = stat()
        guard fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw SecureFileTreeError.systemCall(
                "fstatat",
                relativePath,
                errno
            )
        }
        let entry = secureEntry(from: purge, relativePath: relativePath)
        if allowRenameCtimeChange {
            try validateMovedEntryStat(current, entry: entry)
        } else {
            try validateEntryStat(current, entry: entry)
        }
        return entry
    }

    private func purgeState(
        _ purge: SecureTreePurge
    ) throws -> SecurePurgeState {
        let original = try validatedPurgeEntryIfPresent(
            purge,
            at: purge.originalRelativePath,
            allowRenameCtimeChange: false
        ) != nil
        let tombstone = try validatedPurgeEntryIfPresent(
            purge,
            at: purge.tombstoneRelativePath,
            allowRenameCtimeChange: true
        ) != nil
        let final = try validatedPurgeEntryIfPresent(
            purge,
            at: purge.purgeRelativePath,
            allowRenameCtimeChange: true
        ) != nil
        let presentCount = [original, tombstone, final].filter { $0 }.count
        guard presentCount <= 1 else {
            throw SecureFileTreeError.identityChanged(
                purge.originalRelativePath
            )
        }
        if original { return .original }
        if tombstone { return .tombstone }
        if final { return .purge }
        return .absent
    }

    private func validateMutuallyExclusivePurgeStates(
        _ tombstone: SecureTreeTombstone
    ) throws {
        for purge in tombstone.purges {
            _ = try purgeState(purge)
        }
    }

    private func purgeDeletionOrder(
        _ left: SecureTreePurge,
        _ right: SecureTreePurge
    ) -> Bool {
        let leftDepth = left.tombstoneRelativePath.split(separator: "/").count
        let rightDepth = right.tombstoneRelativePath.split(separator: "/").count
        if leftDepth != rightDepth {
            return leftDepth > rightDepth
        }
        return left.tombstoneRelativePath < right.tombstoneRelativePath
    }

    private func removeEntryAtPath(
        _ relativePath: String,
        purge: SecureTreePurge,
        beforeFinalRemoval: ((SecureTreeEntry) throws -> Void)?,
        afterFinalRename: ((SecureTreePurge) throws -> Void)?
    ) throws {
        let components = try validatedComponents(relativePath)
        let (parentFD, name) = try openParent(
            components,
            path: relativePath,
            missingIsAllowed: true
        )
        guard parentFD >= 0 else {
            return
        }
        defer { Darwin.close(parentFD) }
        try removeEntry(
            parentFD: parentFD,
            name: name,
            entry: secureEntry(from: purge, relativePath: relativePath),
            allowRenameCtimeChange: true,
            beforeFinalRemoval: beforeFinalRemoval,
            purge: purge,
            afterFinalRename: afterFinalRename
        )
    }

    private func removePersistedPurge(
        _ purge: SecureTreePurge
    ) throws {
        guard try purgeState(purge) == .purge else {
            throw SecureFileTreeError.identityChanged(
                purge.purgeRelativePath
            )
        }
        let components = try validatedComponents(purge.purgeRelativePath)
        let (parentFD, name) = try openParent(
            components,
            path: purge.purgeRelativePath,
            missingIsAllowed: false
        )
        defer { Darwin.close(parentFD) }
        _ = try validatedPurgeEntryIfPresent(
            purge,
            at: purge.purgeRelativePath,
            allowRenameCtimeChange: true
        )
        let flags = SecureRemovalFlags.unlinkFlags(kind: purge.kind)
        guard unlinkat(parentFD, name, flags) == 0 else {
            throw SecureFileTreeError.systemCall(
                "unlinkat",
                purge.purgeRelativePath,
                errno
            )
        }
        guard fsync(parentFD) == 0 else {
            throw SecureFileTreeError.systemCall(
                "fsync",
                purge.purgeRelativePath,
                errno
            )
        }
    }

    private func moveToTombstone(
        _ tombstone: SecureTreeTombstone,
        entry: SecureTreeEntry,
        beforeRename: ((SecureTreeTombstone) throws -> Void)?,
        afterRename: ((SecureTreeTombstone) throws -> Void)?
    ) throws {
        let originalComponents = try validatedComponents(
            tombstone.originalRelativePath
        )
        let tombstoneComponents = try validatedComponents(
            tombstone.tombstoneRelativePath
        )
        guard originalComponents.dropLast() == tombstoneComponents.dropLast(),
              tombstoneComponents.last?.hasPrefix(
                ".mac-face-lock-delete-"
              ) == true else {
            throw SecureFileTreeError.invalidRelativePath(
                tombstone.tombstoneRelativePath
            )
        }
        let (parentFD, originalName) = try openParent(
            originalComponents,
            path: tombstone.originalRelativePath,
            missingIsAllowed: true
        )
        guard parentFD >= 0, let movedName = tombstoneComponents.last else {
            return
        }
        defer { Darwin.close(parentFD) }

        var current = stat()
        guard fstatat(
            parentFD,
            originalName,
            &current,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return
            }
            throw SecureFileTreeError.systemCall(
                "fstatat",
                tombstone.originalRelativePath,
                errno
            )
        }
        try validateEntryStat(current, entry: entry)
        try beforeRename?(tombstone)
        guard renameatx_np(
            parentFD,
            originalName,
            parentFD,
            movedName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw SecureFileTreeError.systemCall(
                "renameatx_np",
                tombstone.originalRelativePath,
                errno
            )
        }
        guard fsync(parentFD) == 0 else {
            throw SecureFileTreeError.systemCall(
                "fsync",
                tombstone.originalRelativePath,
                errno
            )
        }
        try afterRename?(tombstone)

        var moved = stat()
        guard fstatat(
            parentFD,
            movedName,
            &moved,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw SecureFileTreeError.systemCall(
                "fstatat",
                tombstone.tombstoneRelativePath,
                errno
            )
        }
        try validateMovedEntryStat(moved, entry: entry)
    }

    private func deleteMovedTree(
        manifest: SecureTreeManifest,
        tombstone: SecureTreeTombstone,
        beforeFinalRemoval: ((SecureTreeEntry) throws -> Void)?,
        afterFinalRename: ((SecureTreePurge) throws -> Void)?
    ) throws {
        let movedEntries = manifest.entriesDeepestFirst.compactMap { entry
            -> SecureTreeEntry? in
            let original = tombstone.originalRelativePath
            guard entry.relativePath == original
                    || entry.relativePath.hasPrefix(original + "/") else {
                return nil
            }
            let suffix = String(entry.relativePath.dropFirst(original.count))
            return SecureTreeEntry(
                relativePath: tombstone.tombstoneRelativePath + suffix,
                identity: entry.identity,
                kind: entry.kind,
                fileVersion: entry.fileVersion
            )
        }
        do {
            try deleteManifestEntries(
                movedEntries,
                renamedRootPath: tombstone.tombstoneRelativePath,
                beforeFinalRemoval: beforeFinalRemoval,
                purges: tombstone.purges,
                afterFinalRename: afterFinalRename
            )
        } catch SecureFileTreeError.identityChanged(let path) {
            guard path == tombstone.tombstoneRelativePath
                    || path.hasPrefix(
                        tombstone.tombstoneRelativePath + "/"
                    ) else {
                throw SecureFileTreeError.identityChanged(path)
            }
            let suffix = String(
                path.dropFirst(tombstone.tombstoneRelativePath.count)
            )
            throw SecureFileTreeError.identityChanged(
                tombstone.originalRelativePath + suffix
            )
        }
    }

    private func deleteManifestEntries(
        _ entries: [SecureTreeEntry],
        renamedRootPath: String? = nil,
        beforeFinalRemoval: ((SecureTreeEntry) throws -> Void)? = nil,
        purges: [SecureTreePurge],
        afterFinalRename: ((SecureTreePurge) throws -> Void)? = nil
    ) throws {
        let purgeByPath = Dictionary(
            uniqueKeysWithValues: purges.map {
                ($0.tombstoneRelativePath, $0)
            }
        )
        for entry in entries {
            guard let purge = purgeByPath[entry.relativePath] else {
                throw SecureFileTreeError.invalidRelativePath(
                    entry.relativePath
                )
            }
            let components = try validatedComponents(entry.relativePath)
            let (parentFD, name) = try openParent(
                components,
                path: entry.relativePath,
                missingIsAllowed: true
            )
            guard parentFD >= 0 else {
                continue
            }
            defer { Darwin.close(parentFD) }
            try removeEntry(
                parentFD: parentFD,
                name: name,
                entry: entry,
                allowRenameCtimeChange:
                    entry.relativePath == renamedRootPath,
                beforeFinalRemoval: beforeFinalRemoval,
                purge: purge,
                afterFinalRename: afterFinalRename
            )
        }
    }

    private func validateEntryStat(
        _ current: stat,
        entry: SecureTreeEntry
    ) throws {
        let (identity, kind) = try Self.checkedIdentity(
            current,
            path: entry.relativePath,
            requiredOwner: requiredOwner
        )
        guard identity == entry.identity,
              kind == entry.kind,
              Self.fileVersion(current, kind: kind) == entry.fileVersion else {
            throw SecureFileTreeError.identityChanged(entry.relativePath)
        }
    }

    private func validateMovedEntryStat(
        _ current: stat,
        entry: SecureTreeEntry
    ) throws {
        let (identity, kind) = try Self.checkedIdentity(
            current,
            path: entry.relativePath,
            requiredOwner: requiredOwner
        )
        guard identity == entry.identity, kind == entry.kind else {
            throw SecureFileTreeError.identityChanged(entry.relativePath)
        }
        if let expected = entry.fileVersion {
            guard let actual = Self.fileVersion(current, kind: kind),
                  actual.logicalSize == expected.logicalSize,
                  actual.modificationSeconds == expected.modificationSeconds,
                  actual.modificationNanoseconds
                    == expected.modificationNanoseconds else {
                throw SecureFileTreeError.identityChanged(entry.relativePath)
            }
        }
    }

    private static func checkedIdentity(
        _ statValue: stat,
        path: String,
        requiredOwner: uid_t
    ) throws -> (SecureFileIdentity, SecureTreeEntry.Kind) {
        guard statValue.st_uid == requiredOwner else {
            throw SecureFileTreeError.ownerMismatch(path)
        }
        let mode = statValue.st_mode & S_IFMT
        if mode == S_IFLNK {
            throw SecureFileTreeError.symbolicLink(path)
        }
        if mode == S_IFREG {
            guard statValue.st_nlink == 1 else {
                throw SecureFileTreeError.hardLink(path)
            }
            return (
                SecureFileIdentity(
                    device: UInt64(statValue.st_dev),
                    inode: UInt64(statValue.st_ino)
                ),
                .file
            )
        }
        guard mode == S_IFDIR else {
            throw SecureFileTreeError.specialFile(path)
        }
        return (
            SecureFileIdentity(
                device: UInt64(statValue.st_dev),
                inode: UInt64(statValue.st_ino)
            ),
            .directory
        )
    }

    private func validatedComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw SecureFileTreeError.invalidRelativePath(relativePath)
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SecureFileTreeError.invalidRelativePath(relativePath)
        }
        return components
    }

    private func validatedSingleComponent(_ relativePath: String) throws -> String {
        let components = try validatedComponents(relativePath)
        guard components.count == 1, let name = components.first else {
            throw SecureFileTreeError.invalidRelativePath(relativePath)
        }
        return name
    }

    private func validatedFileFingerprint(
        _ statValue: stat,
        path: String,
        maximumBytes: Int,
        requiredMode: mode_t
    ) throws -> SecureFileFingerprint {
        let (identity, kind) = try Self.checkedIdentity(
            statValue,
            path: path,
            requiredOwner: requiredOwner
        )
        guard kind == .file else {
            throw SecureFileTreeError.specialFile(path)
        }
        guard statValue.st_mode & 0o7777 == requiredMode else {
            throw SecureFileTreeError.specialFile(path)
        }
        guard
            statValue.st_size >= 0,
            UInt64(statValue.st_size) <= UInt64(maximumBytes),
            let version = Self.fileVersion(statValue, kind: .file)
        else {
            throw SecureFileTreeError.byteBudgetExceeded
        }
        return SecureFileFingerprint(
            identity: identity,
            owner: statValue.st_uid,
            mode: statValue.st_mode & 0o7777,
            linkCount: UInt64(statValue.st_nlink),
            version: version
        )
    }

    private func fileFingerprintIfPresent(
        _ name: String,
        path: String,
        maximumBytes: Int,
        requiredMode: mode_t
    ) throws -> SecureFileFingerprint? {
        var result = stat()
        guard fstatat(rootFD, name, &result, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw SecureFileTreeError.systemCall("fstatat", path, errno)
        }
        return try validatedFileFingerprint(
            result,
            path: path,
            maximumBytes: maximumBytes,
            requiredMode: requiredMode
        )
    }

    private func readAll(
        _ fileDescriptor: Int32,
        path: String,
        maximumBytes: Int
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count == 0 {
                return result
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw SecureFileTreeError.systemCall("read", path, errno)
            }
            let (newCount, overflow) = result.count.addingReportingOverflow(
                Int(count)
            )
            guard !overflow, newCount <= maximumBytes else {
                throw SecureFileTreeError.byteBudgetExceeded
            }
            result.append(contentsOf: buffer.prefix(Int(count)))
        }
    }

    private func writeAll(
        _ fileDescriptor: Int32,
        data: Data,
        path: String
    ) throws {
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
                    throw SecureFileTreeError.systemCall("write", path, errno)
                }
                guard written > 0 else {
                    throw SecureFileTreeError.systemCall("write", path, EIO)
                }
                offset += written
            }
        }
    }

    private func capturePathBinding(
        includeRootVersion: Bool
    ) throws -> [SecureDirectoryBinding] {
        var currentFD = dup(ancestorFD)
        guard currentFD >= 0 else {
            throw SecureFileTreeError.systemCall("dup", rootPath, errno)
        }
        defer { Darwin.close(currentFD) }

        var bindings: [SecureDirectoryBinding] = []
        var ancestorStat = stat()
        guard fstat(currentFD, &ancestorStat) == 0 else {
            throw SecureFileTreeError.systemCall("fstat", rootPath, errno)
        }
        bindings.append(
            Self.directoryBinding(ancestorStat, includeVersion: true)
        )

        for (index, component) in rootComponents.enumerated() {
            let nextFD = openat(
                currentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard nextFD >= 0 else {
                throw SecureFileTreeError.identityChanged(rootPath)
            }
            var entryStat = stat()
            guard fstat(nextFD, &entryStat) == 0 else {
                let savedErrno = errno
                Darwin.close(nextFD)
                throw SecureFileTreeError.systemCall(
                    "fstat",
                    component,
                    savedErrno
                )
            }
            bindings.append(
                Self.directoryBinding(
                    entryStat,
                    includeVersion: includeRootVersion
                        || index < rootComponents.count - 1
                )
            )
            Darwin.close(currentFD)
            currentFD = nextFD
        }
        return bindings
    }

    private static func directoryBinding(
        _ statValue: stat,
        includeVersion: Bool
    ) -> SecureDirectoryBinding {
        SecureDirectoryBinding(
            identity: SecureFileIdentity(
                device: UInt64(statValue.st_dev),
                inode: UInt64(statValue.st_ino)
            ),
            version: includeVersion
                ? SecureDirectoryVersion(
                    modificationSeconds: Int64(statValue.st_mtimespec.tv_sec),
                    modificationNanoseconds: Int64(statValue.st_mtimespec.tv_nsec),
                    changeSeconds: Int64(statValue.st_ctimespec.tv_sec),
                    changeNanoseconds: Int64(statValue.st_ctimespec.tv_nsec)
                )
                : nil
        )
    }

    private func openParent(
        _ components: [String],
        path: String,
        missingIsAllowed: Bool = false
    ) throws -> (Int32, String) {
        var currentFD = dup(rootFD)
        guard currentFD >= 0 else {
            throw SecureFileTreeError.systemCall("dup", rootPath, errno)
        }
        guard let name = components.last else {
            Darwin.close(currentFD)
            throw SecureFileTreeError.invalidRelativePath(path)
        }

        var traversed: [String] = []
        for component in components.dropLast() {
            traversed.append(component)
            let currentPath = traversed.joined(separator: "/")
            var entryStat = stat()
            guard fstatat(currentFD, component, &entryStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                let savedErrno = errno
                Darwin.close(currentFD)
                if missingIsAllowed, savedErrno == ENOENT {
                    return (-1, name)
                }
                throw SecureFileTreeError.systemCall("fstatat", currentPath, savedErrno)
            }
            let identity: SecureFileIdentity
            let kind: SecureTreeEntry.Kind
            do {
                (identity, kind) = try Self.checkedIdentity(
                    entryStat,
                    path: currentPath,
                    requiredOwner: requiredOwner
                )
            } catch {
                Darwin.close(currentFD)
                throw error
            }
            guard kind == .directory else {
                Darwin.close(currentFD)
                throw SecureFileTreeError.specialFile(currentPath)
            }
            let nextFD = openat(
                currentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard nextFD >= 0 else {
                let savedErrno = errno
                Darwin.close(currentFD)
                if savedErrno == ELOOP {
                    throw SecureFileTreeError.symbolicLink(currentPath)
                }
                throw SecureFileTreeError.systemCall("openat", currentPath, savedErrno)
            }
            var openedStat = stat()
            guard fstat(nextFD, &openedStat) == 0 else {
                let savedErrno = errno
                Darwin.close(nextFD)
                Darwin.close(currentFD)
                throw SecureFileTreeError.systemCall("fstat", currentPath, savedErrno)
            }
            let openedIdentity = SecureFileIdentity(
                device: UInt64(openedStat.st_dev),
                inode: UInt64(openedStat.st_ino)
            )
            guard openedIdentity == identity else {
                Darwin.close(nextFD)
                Darwin.close(currentFD)
                throw SecureFileTreeError.identityChanged(currentPath)
            }
            Darwin.close(currentFD)
            currentFD = nextFD
        }
        return (currentFD, name)
    }

    private func collectEntry(
        parentFD: Int32,
        name: String,
        relativePath: String,
        initialStat: stat,
        budget: SecureTreeBudget,
        entriesByPath: inout [String: SecureTreeEntry],
        logicalBytes: inout UInt64
    ) throws {
        let (identity, kind) = try Self.checkedIdentity(
            initialStat,
            path: relativePath,
            requiredOwner: requiredOwner
        )
        if entriesByPath[relativePath] == nil {
            let (newCount, countOverflow) = entriesByPath.count.addingReportingOverflow(1)
            guard !countOverflow, newCount <= budget.maximumEntries else {
                throw SecureFileTreeError.entryBudgetExceeded
            }
            if kind == .file {
                guard initialStat.st_size >= 0 else {
                    throw SecureFileTreeError.byteBudgetExceeded
                }
                let (newBytes, byteOverflow) = logicalBytes.addingReportingOverflow(
                    UInt64(initialStat.st_size)
                )
                guard !byteOverflow, newBytes <= budget.maximumLogicalBytes else {
                    throw SecureFileTreeError.byteBudgetExceeded
                }
                logicalBytes = newBytes
            }
            entriesByPath[relativePath] = SecureTreeEntry(
                relativePath: relativePath,
                identity: identity,
                kind: kind,
                fileVersion: Self.fileVersion(initialStat, kind: kind)
            )
        }

        guard kind == .directory else {
            return
        }
        let directoryFD = openat(
            parentFD,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            if errno == ELOOP {
                throw SecureFileTreeError.symbolicLink(relativePath)
            }
            throw SecureFileTreeError.systemCall("openat", relativePath, errno)
        }
        defer { Darwin.close(directoryFD) }

        var openedStat = stat()
        guard fstat(directoryFD, &openedStat) == 0 else {
            throw SecureFileTreeError.systemCall("fstat", relativePath, errno)
        }
        let openedIdentity = SecureFileIdentity(
            device: UInt64(openedStat.st_dev),
            inode: UInt64(openedStat.st_ino)
        )
        guard openedIdentity == identity else {
            throw SecureFileTreeError.identityChanged(relativePath)
        }

        let duplicateFD = dup(directoryFD)
        guard duplicateFD >= 0 else {
            throw SecureFileTreeError.systemCall("dup", relativePath, errno)
        }
        guard let directory = fdopendir(duplicateFD) else {
            let savedErrno = errno
            Darwin.close(duplicateFD)
            throw SecureFileTreeError.systemCall("fdopendir", relativePath, savedErrno)
        }
        defer { closedir(directory) }

        var childNames: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let childName = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if childName != "." && childName != ".." {
                childNames.append(childName)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw SecureFileTreeError.systemCall("readdir", relativePath, errno)
        }

        for childName in childNames.sorted() {
            let childPath = relativePath + "/" + childName
            var childStat = stat()
            guard fstatat(directoryFD, childName, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SecureFileTreeError.systemCall("fstatat", childPath, errno)
            }
            try collectEntry(
                parentFD: directoryFD,
                name: childName,
                relativePath: childPath,
                initialStat: childStat,
                budget: budget,
                entriesByPath: &entriesByPath,
                logicalBytes: &logicalBytes
            )
        }
    }

    private func requireStableRoot() throws {
        var current = stat()
        guard fstat(rootFD, &current) == 0 else {
            throw SecureFileTreeError.systemCall("fstat", rootPath, errno)
        }
        let openedIdentity = SecureFileIdentity(
            device: UInt64(current.st_dev),
            inode: UInt64(current.st_ino)
        )
        guard openedIdentity == rootIdentity else {
            throw SecureFileTreeError.identityChanged(rootPath)
        }

        var currentFD = dup(ancestorFD)
        guard currentFD >= 0 else {
            throw SecureFileTreeError.systemCall("dup", rootPath, errno)
        }
        defer { Darwin.close(currentFD) }

        var currentPath: [String] = []
        for component in rootComponents {
            currentPath.append(component)
            let relativePath = currentPath.joined(separator: "/")
            var entryStat = stat()
            guard fstatat(currentFD, component, &entryStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT {
                    throw SecureFileTreeError.identityChanged(rootPath)
                }
                throw SecureFileTreeError.systemCall("fstatat", relativePath, errno)
            }
            let (identity, kind) = try Self.checkedIdentity(
                entryStat,
                path: relativePath,
                requiredOwner: requiredOwner
            )
            guard kind == .directory else {
                throw SecureFileTreeError.identityChanged(rootPath)
            }
            let nextFD = openat(
                currentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard nextFD >= 0 else {
                if errno == ELOOP || errno == ENOENT {
                    throw SecureFileTreeError.identityChanged(rootPath)
                }
                throw SecureFileTreeError.systemCall("openat", relativePath, errno)
            }
            var resolvedStat = stat()
            guard fstat(nextFD, &resolvedStat) == 0 else {
                let savedErrno = errno
                Darwin.close(nextFD)
                throw SecureFileTreeError.systemCall("fstat", relativePath, savedErrno)
            }
            let resolvedIdentity = SecureFileIdentity(
                device: UInt64(resolvedStat.st_dev),
                inode: UInt64(resolvedStat.st_ino)
            )
            guard resolvedIdentity == identity else {
                Darwin.close(nextFD)
                throw SecureFileTreeError.identityChanged(rootPath)
            }
            Darwin.close(currentFD)
            currentFD = nextFD
        }

        var reboundStat = stat()
        guard fstat(currentFD, &reboundStat) == 0 else {
            throw SecureFileTreeError.systemCall("fstat", rootPath, errno)
        }
        let reboundIdentity = SecureFileIdentity(
            device: UInt64(reboundStat.st_dev),
            inode: UInt64(reboundStat.st_ino)
        )
        guard reboundIdentity == rootIdentity else {
            throw SecureFileTreeError.identityChanged(rootPath)
        }
    }

    private func removeEntry(
        parentFD: Int32,
        name: String,
        entry: SecureTreeEntry,
        allowRenameCtimeChange: Bool = false,
        beforeFinalRemoval: ((SecureTreeEntry) throws -> Void)? = nil,
        purge: SecureTreePurge,
        afterFinalRename: ((SecureTreePurge) throws -> Void)? = nil
    ) throws {
        var current = stat()
        guard fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return
            }
            throw SecureFileTreeError.systemCall("fstatat", entry.relativePath, errno)
        }
        let (currentIdentity, currentKind) = try Self.checkedIdentity(
            current,
            path: entry.relativePath,
            requiredOwner: requiredOwner
        )
        guard currentIdentity == entry.identity,
              currentKind == entry.kind else {
            throw SecureFileTreeError.identityChanged(entry.relativePath)
        }
        if allowRenameCtimeChange, let expected = entry.fileVersion {
            guard let actual = Self.fileVersion(current, kind: currentKind),
                  actual.logicalSize == expected.logicalSize,
                  actual.modificationSeconds == expected.modificationSeconds,
                  actual.modificationNanoseconds
                    == expected.modificationNanoseconds else {
                throw SecureFileTreeError.identityChanged(entry.relativePath)
            }
        } else if Self.fileVersion(current, kind: currentKind)
                    != entry.fileVersion {
            throw SecureFileTreeError.identityChanged(entry.relativePath)
        }
        try beforeFinalRemoval?(entry)

        // Darwin has no unlink-by-inode/fd operation. Move the pathname through
        // one more exclusive, unpredictable name and verify the moved inode.
        // This closes the auditable public-name check/delete window. The final
        // unlink remains pathname-based, so the security model also relies on
        // this private name not being disclosed to a concurrent same-UID actor.
        guard purge.tombstoneRelativePath == entry.relativePath,
              purge.identity == entry.identity,
              purge.kind == entry.kind,
              purge.fileVersion == entry.fileVersion else {
            throw SecureFileTreeError.invalidRelativePath(
                purge.purgeRelativePath
            )
        }
        let entryComponents = try validatedComponents(entry.relativePath)
        let purgeComponents = try validatedComponents(
            purge.purgeRelativePath
        )
        guard entryComponents.dropLast() == purgeComponents.dropLast(),
              let purgeName = purgeComponents.last,
              purgeName.hasPrefix(".mac-face-lock-purge-"),
              purgeName != ".mac-face-lock-purge-" else {
            throw SecureFileTreeError.invalidRelativePath(
                purge.purgeRelativePath
            )
        }
        guard renameatx_np(
            parentFD,
            name,
            parentFD,
            purgeName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw SecureFileTreeError.systemCall(
                "renameatx_np",
                entry.relativePath,
                errno
            )
        }
        guard fsync(parentFD) == 0 else {
            let savedErrno = errno
            _ = renameatx_np(
                parentFD,
                purgeName,
                parentFD,
                name,
                UInt32(RENAME_EXCL)
            )
            throw SecureFileTreeError.systemCall(
                "fsync",
                entry.relativePath,
                savedErrno
            )
        }
        try afterFinalRename?(purge)

        do {
            var quarantined = stat()
            guard fstatat(
                parentFD,
                purgeName,
                &quarantined,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw SecureFileTreeError.systemCall(
                    "fstatat",
                    entry.relativePath,
                    errno
                )
            }
            try validateMovedEntryStat(quarantined, entry: entry)
        } catch {
            try restoreFinalQuarantine(
                parentFD: parentFD,
                purgeName: purgeName,
                originalName: name,
                path: entry.relativePath
            )
            throw error
        }

        let flags = SecureRemovalFlags.unlinkFlags(kind: entry.kind)
        guard unlinkat(parentFD, purgeName, flags) == 0 else {
            let savedErrno = errno
            try restoreFinalQuarantine(
                parentFD: parentFD,
                purgeName: purgeName,
                originalName: name,
                path: entry.relativePath
            )
            throw SecureFileTreeError.systemCall(
                "unlinkat",
                entry.relativePath,
                savedErrno
            )
        }
        guard fsync(parentFD) == 0 else {
            throw SecureFileTreeError.systemCall(
                "fsync",
                entry.relativePath,
                errno
            )
        }
    }

    private func restoreFinalQuarantine(
        parentFD: Int32,
        purgeName: String,
        originalName: String,
        path: String
    ) throws {
        guard renameatx_np(
            parentFD,
            purgeName,
            parentFD,
            originalName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw SecureFileTreeError.systemCall(
                "renameatx_np restore",
                path,
                errno
            )
        }
        guard fsync(parentFD) == 0 else {
            throw SecureFileTreeError.systemCall("fsync", path, errno)
        }
    }

    private static func fileVersion(
        _ statValue: stat,
        kind: SecureTreeEntry.Kind
    ) -> SecureRegularFileVersion? {
        guard kind == .file, statValue.st_size >= 0 else {
            return nil
        }
        return SecureRegularFileVersion(
            logicalSize: UInt64(statValue.st_size),
            modificationSeconds: Int64(statValue.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(statValue.st_mtimespec.tv_nsec),
            changeSeconds: Int64(statValue.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(statValue.st_ctimespec.tv_nsec)
        )
    }
}
