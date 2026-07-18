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
}

struct SecureTreeManifest: Codable, Equatable, Sendable {
    let rootIdentity: SecureFileIdentity
    let entriesDeepestFirst: [SecureTreeEntry]
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
        guard manifest.rootIdentity == rootIdentity else {
            throw SecureFileTreeError.identityChanged(rootPath)
        }
        try requireStableRoot()

        for entry in manifest.entriesDeepestFirst {
            let components = try validatedComponents(entry.relativePath)
            let (parentFD, name) = try openParent(
                components,
                path: entry.relativePath,
                missingIsAllowed: true
            )
            guard parentFD >= 0 else {
                continue
            }
            do {
                defer { Darwin.close(parentFD) }
                try removeEntry(parentFD: parentFD, name: name, entry: entry)
            }
        }
        try requireStableRoot()
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
                kind: kind
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
        entry: SecureTreeEntry
    ) throws {
        var current = stat()
        guard fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return
            }
            throw SecureFileTreeError.systemCall("fstatat", entry.relativePath, errno)
        }
        let currentIdentity = SecureFileIdentity(
            device: UInt64(current.st_dev),
            inode: UInt64(current.st_ino)
        )
        guard currentIdentity == entry.identity else {
            throw SecureFileTreeError.identityChanged(entry.relativePath)
        }
        let flags = entry.kind == .directory ? AT_REMOVEDIR : 0
        guard unlinkat(parentFD, name, flags) == 0 else {
            throw SecureFileTreeError.systemCall("unlinkat", entry.relativePath, errno)
        }
    }
}
