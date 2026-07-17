import CryptoKit
import Darwin
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    case injected

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        case .injected:
            return "injected migration failure"
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure.assertion(message)
    }
}

private func validOwnerTemplate(rows: Int = 2) -> Data {
    let shape = "(\(rows), 9216)"
    var header = "{'descr': '<f4', 'fortran_order': False, 'shape': \(shape), }"
    let headerStart = 10
    let padding = (64 - ((headerStart + header.utf8.count + 1) % 64)) % 64
    header += String(repeating: " ", count: padding) + "\n"

    var data = Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59, 0x01, 0x00])
    let headerLength = UInt16(header.utf8.count)
    data.append(UInt8(headerLength & 0xff))
    data.append(UInt8(headerLength >> 8))
    data.append(Data(header.utf8))
    let one = Float(1).bitPattern.littleEndian
    for _ in 0..<(rows * 9_216) {
        var bits = one
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
}

private func activityLine(index: Int) -> String {
    """
    {"schema_version":1,"id":"event-\(index)","timestamp":"2026-07-17T12:00:00+08:00","type":"decision","title":"Event \(index)","detail":"local","severity":"info","metadata":{"frames_checked":\(index)}}
    """
}

private func createSource(at root: URL, activityBytes: Data? = nil) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: root.appendingPathComponent("config"),
        withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
        at: root.appendingPathComponent("data"),
        withIntermediateDirectories: true
    )
    try Data("print('agent')\n".utf8).write(
        to: root.appendingPathComponent("agent.py")
    )
    try Data("{\"mode\":\"presence_guard\",\"camera_index\":0}".utf8).write(
        to: root.appendingPathComponent("config/config.json")
    )
    try validOwnerTemplate().write(
        to: root.appendingPathComponent("data/owner_face.npy")
    )
    try Data(
        "{\"schema_version\":1,\"appearance\":\"dark\",\"accent\":\"amethyst\"}".utf8
    ).write(to: root.appendingPathComponent("data/ui-preferences.json"))
    let activity = activityBytes
        ?? Data(((0..<4).map(activityLine).joined(separator: "\n") + "\n").utf8)
    try activity.write(to: root.appendingPathComponent("data/activity.jsonl"))
}

private func byteSnapshot(of root: URL) throws -> [String: String] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
        options: [],
        errorHandler: { _, _ in false }
    ) else {
        return [:]
    }
    var snapshot: [String: String] = [:]
    for case let url as URL in enumerator {
        let relative = String(url.path.dropFirst(root.path.count + 1))
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        )
        if values.isSymbolicLink == true {
            snapshot[relative] = "symlink:\(try fileManager.destinationOfSymbolicLink(atPath: url.path))"
        } else if values.isDirectory == true {
            snapshot[relative] = "directory"
        } else if values.isRegularFile == true {
            let digest = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }
                .joined()
            snapshot[relative] = "file:\(digest)"
        } else {
            snapshot[relative] = "special"
        }
    }
    return snapshot
}

@main
struct SourceDataMigratorTests {
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("mac-face-lock-migration-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try createSource(at: source)
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let migrator = SourceDataMigrator(candidateRootURLs: [source])
        let candidates = migrator.discoverCandidates()
        try require(candidates.count == 1, "valid source install was not discovered")
        try require(
            candidates[0].availableItems == Set(MigrationItem.allCases),
            "discovery did not report all allowed items"
        )

        let sourceBefore = try byteSnapshot(of: source)
        let result = try migrator.import(candidate: candidates[0], destination: destination)
        try require(
            result.importedItems == Set(MigrationItem.allCases),
            "successful import omitted an allowed item"
        )
        let importedConfig = try Data(
            contentsOf: destination.appendingPathComponent("config/config.json")
        )
        let sourceConfig = try Data(
            contentsOf: source.appendingPathComponent("config/config.json")
        )
        try require(
            importedConfig == sourceConfig,
            "config was not imported byte-for-byte"
        )
        let importedOwner = try Data(
            contentsOf: destination.appendingPathComponent("data/owner_face.npy")
        )
        let sourceOwner = try Data(
            contentsOf: source.appendingPathComponent("data/owner_face.npy")
        )
        try require(
            importedOwner == sourceOwner,
            "owner template was not imported byte-for-byte"
        )
        let sourceAfter = try byteSnapshot(of: source)
        try require(
            sourceAfter == sourceBefore,
            "successful import modified the source tree"
        )

        let malformedSource = root.appendingPathComponent("malformed-source")
        try createSource(at: malformedSource)
        try Data("not-a-numpy-template".utf8).write(
            to: malformedSource.appendingPathComponent("data/owner_face.npy")
        )
        let malformedCandidate = try requireCandidate(
            SourceDataMigrator(candidateRootURLs: [malformedSource])
        )
        let malformedDestination = root.appendingPathComponent("malformed-destination")
        try fileManager.createDirectory(at: malformedDestination, withIntermediateDirectories: true)
        let malformedBefore = try byteSnapshot(of: malformedDestination)
        do {
            _ = try migrator.import(
                candidate: malformedCandidate,
                destination: malformedDestination
            )
            throw TestFailure.assertion("malformed owner template was accepted")
        } catch let error as SourceDataMigrationError {
            try require(
                error == .invalidOwnerTemplate,
                "malformed owner template returned the wrong error"
            )
        }
        let malformedAfter = try byteSnapshot(of: malformedDestination)
        try require(
            malformedAfter == malformedBefore,
            "validation failure changed destination bytes"
        )

        let unsafeConfigSource = root.appendingPathComponent("unsafe-config-source")
        try createSource(at: unsafeConfigSource)
        try Data(
            "{\"mode\":\"presence_guard\",\"lock_on_camera_error\":true,\"cooldown_seconds_after_lock\":300,\"camera_error_cooldown_seconds\":300,\"event_notify_on_lock\":false,\"event_notify_script\":\"\"}".utf8
        ).write(to: unsafeConfigSource.appendingPathComponent("config/config.json"))
        let unsafeConfigMigrator = SourceDataMigrator(
            candidateRootURLs: [unsafeConfigSource]
        )
        let unsafeConfigCandidate = try requireCandidate(unsafeConfigMigrator)
        let unsafeConfigDestination = root.appendingPathComponent(
            "unsafe-config-destination"
        )
        try fileManager.createDirectory(
            at: unsafeConfigDestination,
            withIntermediateDirectories: true
        )
        do {
            _ = try unsafeConfigMigrator.import(
                candidate: unsafeConfigCandidate,
                destination: unsafeConfigDestination
            )
            throw TestFailure.assertion("fail-open violating config was accepted")
        } catch let error as SourceDataMigrationError {
            try require(
                error == .invalidConfiguration,
                "unsafe config returned the wrong validation error"
            )
        }

        let rollbackDestination = root.appendingPathComponent("rollback-destination")
        try fileManager.createDirectory(
            at: rollbackDestination.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: rollbackDestination.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        try Data("old-config".utf8).write(
            to: rollbackDestination.appendingPathComponent("config/config.json")
        )
        try Data("old-template".utf8).write(
            to: rollbackDestination.appendingPathComponent("data/owner_face.npy")
        )
        let destinationBefore = try byteSnapshot(of: rollbackDestination)
        let sourceBeforeRollback = try byteSnapshot(of: source)
        let failingMigrator = SourceDataMigrator(
            candidateRootURLs: [source],
            faultInjector: { point in
                if point == .afterJournalDirectoryFsync("committed", 1) {
                    throw TestFailure.injected
                }
            }
        )
        do {
            _ = try failingMigrator.import(
                candidate: candidates[0],
                destination: rollbackDestination
            )
            throw TestFailure.assertion("injected migration failure did not fail")
        } catch TestFailure.injected {
            // Expected.
        }
        let destinationAfter = try byteSnapshot(of: rollbackDestination)
        try require(
            destinationAfter == destinationBefore,
            "rollback did not restore destination byte-for-byte"
        )
        let sourceAfterRollback = try byteSnapshot(of: source)
        try require(
            sourceAfterRollback == sourceBeforeRollback,
            "failed import modified the source tree"
        )

        try testActivityBudget(root: root)
        try testUntrustedSourceEntries(root: root)
        try testOverlapIsRejectedBeforeAnyDestinationWrite(root: root)
        try testCandidateIdentityAndHardLinksAreRejected(root: root)
        try testPayloadProvenanceIsRevalidated(root: root)
        try testCrashRecoveryAtEveryDurabilityBoundary(root: root)
        try testRollbackRecoveryAtEveryDurabilityBoundary(root: root)
        try testDestinationParentReplacementCannotEscape(root: root)
        try testDestinationRootReplacementKeepsOneLock(root: root)
        try testCrossProcessImportLock(root: root)
        try testUnknownTransactionsBlockRecovery(root: root)
        try testReorderedNumpyHeaderUsesSharedValidator(root: root)
        try testLaunchAgentProvenanceIsExactAndRevalidated(root: root)

        print("SourceDataMigratorTests passed")
    }

    private static func requireCandidate(
        _ migrator: SourceDataMigrator
    ) throws -> SourceInstallCandidate {
        guard let candidate = migrator.discoverCandidates().first else {
            throw TestFailure.assertion("source candidate was not discovered")
        }
        return candidate
    }

    private static func testActivityBudget(root: URL) throws {
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("large-activity-source")
        var activity = Data(repeating: 0x78, count: 4 * 1_024 * 1_024 + 32 * 1_024)
        activity.append(0x0A)
        activity.append(Data((activityLine(index: 999) + "\n").utf8))
        try createSource(at: source, activityBytes: activity)
        let migrator = SourceDataMigrator(candidateRootURLs: [source])
        let candidate = try requireCandidate(migrator)
        let destination = root.appendingPathComponent("large-activity-destination")
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        _ = try migrator.import(candidate: candidate, destination: destination)
        let imported = try Data(
            contentsOf: destination.appendingPathComponent("data/activity.jsonl")
        )
        try require(
            imported.count <= 4 * 1_024 * 1_024,
            "activity import exceeded the 4 MiB scan budget"
        )
        try require(
            imported == Data((activityLine(index: 999) + "\n").utf8),
            "activity import did not retain only complete validated tail records"
        )
    }

    private static func testUntrustedSourceEntries(root: URL) throws {
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("symlink-source")
        try createSource(at: source)
        let outside = root.appendingPathComponent("outside-config")
        try Data("{\"mode\":\"outside\"}".utf8).write(to: outside)
        try fileManager.removeItem(at: source.appendingPathComponent("config/config.json"))
        try fileManager.createSymbolicLink(
            at: source.appendingPathComponent("config/config.json"),
            withDestinationURL: outside
        )
        let migrator = SourceDataMigrator(candidateRootURLs: [source])
        try require(
            migrator.discoverCandidates().isEmpty,
            "candidate discovery followed a source symlink"
        )

        let fifoSource = root.appendingPathComponent("fifo-source")
        try createSource(at: fifoSource)
        let preferences = fifoSource.appendingPathComponent("data/ui-preferences.json")
        try fileManager.removeItem(at: preferences)
        try require(
            mkfifo(preferences.path, 0o600) == 0,
            "test FIFO could not be created"
        )
        let fifoMigrator = SourceDataMigrator(candidateRootURLs: [fifoSource])
        try require(
            fifoMigrator.discoverCandidates().isEmpty,
            "candidate discovery accepted a special source file"
        )
    }

    private static func testOverlapIsRejectedBeforeAnyDestinationWrite(
        root: URL
    ) throws {
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("overlap-source")
        try createSource(at: source)
        let migrator = SourceDataMigrator(candidateRootURLs: [source])
        let candidate = try requireCandidate(migrator)
        let sourceBefore = try byteSnapshot(of: source)
        for destination in [
            source,
            source.appendingPathComponent("nested"),
            source.deletingLastPathComponent(),
        ] {
            do {
                _ = try migrator.import(candidate: candidate, destination: destination)
                throw TestFailure.assertion("overlapping source/destination was accepted")
            } catch let error as SourceDataMigrationError {
                try require(error == .sourceDestinationOverlap, "wrong overlap error")
            }
            let sourceAfter = try byteSnapshot(of: source)
            try require(
                sourceAfter == sourceBefore,
                "overlap rejection modified the source before returning"
            )
        }

        let alias = root.appendingPathComponent("overlap-alias")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: source)
        do {
            _ = try migrator.import(candidate: candidate, destination: alias)
            throw TestFailure.assertion("canonical symlink overlap was accepted")
        } catch let error as SourceDataMigrationError {
            try require(error == .sourceDestinationOverlap, "wrong alias overlap error")
        }
    }

    private static func testCandidateIdentityAndHardLinksAreRejected(
        root: URL
    ) throws {
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("identity-source")
        try createSource(at: source)
        let migrator = SourceDataMigrator(candidateRootURLs: [source])
        let candidate = try requireCandidate(migrator)
        let moved = root.appendingPathComponent("identity-source-moved")
        try fileManager.moveItem(at: source, to: moved)
        try createSource(at: source)
        let destination = root.appendingPathComponent("identity-destination")
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            _ = try migrator.import(candidate: candidate, destination: destination)
            throw TestFailure.assertion("replaced candidate root identity was accepted")
        } catch let error as SourceDataMigrationError {
            try require(error == .sourceChanged("."), "wrong root identity error")
        }

        let hardlinkSource = root.appendingPathComponent("hardlink-source")
        try createSource(at: hardlinkSource)
        let outside = root.appendingPathComponent("hardlink-preferences")
        try Data(
            "{\"schema_version\":1,\"appearance\":\"dark\",\"accent\":\"amethyst\"}".utf8
        ).write(to: outside)
        let preferences = hardlinkSource.appendingPathComponent(
            "data/ui-preferences.json"
        )
        try fileManager.removeItem(at: preferences)
        try fileManager.linkItem(at: outside, to: preferences)
        let hardlinkMigrator = SourceDataMigrator(candidateRootURLs: [hardlinkSource])
        try require(
            hardlinkMigrator.discoverCandidates().isEmpty,
            "candidate discovery accepted a hard-linked source input"
        )
    }

    private static func testCrashRecoveryAtEveryDurabilityBoundary(
        root: URL
    ) throws {
        var points: [MigrationFaultPoint] = []
        for index in 0..<4 {
            points.append(.afterStageFileFsync(index))
            points.append(.afterBackupFileFsync(index))
        }
        points.append(.afterPreparedDirectoryFsync)
        let journalCheckpoints: [(String, Int)] =
            [("initial", -1)]
            + (0..<4).map { ("intent", $0) }
            + (0..<4).map { ("committed", $0) }
            + [("complete", -1)]
        for (checkpoint, index) in journalCheckpoints {
            points.append(.afterJournalFileFsync(checkpoint, index))
            points.append(.afterJournalRename(checkpoint, index))
            points.append(.afterJournalDirectoryFsync(checkpoint, index))
        }
        for index in 0..<4 {
            points.append(.afterTargetRename(index))
            points.append(.afterDestinationDirectoryFsync(index))
        }
        for (index, crashPoint) in points.enumerated() {
            let source = root.appendingPathComponent("crash-source-\(index)")
            let destination = root.appendingPathComponent("crash-destination-\(index)")
            try createSource(at: source)
            try FileManager.default.createDirectory(
                at: destination.appendingPathComponent("config"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: destination.appendingPathComponent("data"),
                withIntermediateDirectories: true
            )
            try Data("old-config".utf8).write(
                to: destination.appendingPathComponent("config/config.json")
            )
            try Data("old-owner".utf8).write(
                to: destination.appendingPathComponent("data/owner_face.npy")
            )
            try Data("old-preferences".utf8).write(
                to: destination.appendingPathComponent("data/ui-preferences.json")
            )
            try Data("old-activity".utf8).write(
                to: destination.appendingPathComponent("data/activity.jsonl")
            )
            let oldSnapshot = try byteSnapshot(of: destination)
            let migrator = SourceDataMigrator(
                candidateRootURLs: [source],
                faultInjector: { point in
                    if point == crashPoint {
                        throw SimulatedMigrationCrash()
                    }
                }
            )
            let candidate = try requireCandidate(migrator)
            do {
                _ = try migrator.import(candidate: candidate, destination: destination)
                throw TestFailure.assertion("fault point \(crashPoint) did not stop import")
            } catch is SimulatedMigrationCrash {
                // Simulates process termination: no in-process rollback.
            }

            let recovering = SourceDataMigrator(candidateRootURLs: [])
            try recovering.recoverPendingImports(destination: destination)
            let completionPoints: [MigrationFaultPoint] = [
                .afterJournalFileFsync("complete", -1),
                .afterJournalRename("complete", -1),
                .afterJournalDirectoryFsync("complete", -1),
            ]
            if completionPoints.contains(crashPoint)
                && crashPoint != .afterJournalFileFsync("complete", -1) {
                let destinationConfig = try Data(
                    contentsOf: destination.appendingPathComponent("config/config.json")
                )
                let sourceConfig = try Data(
                    contentsOf: source.appendingPathComponent("config/config.json")
                )
                try require(
                    destinationConfig == sourceConfig,
                    "completed transaction did not recover to all-new"
                )
            } else {
                let recovered = try byteSnapshot(of: destination)
                    .filter { !$0.key.hasPrefix("backups") && $0.key != ".migration.lock" }
                let expected = oldSnapshot
                    .filter { !$0.key.hasPrefix("backups") && $0.key != ".migration.lock" }
                try require(recovered == expected, "crash recovery did not restore all-old")
            }
            try recovering.recoverPendingImports(destination: destination)
        }
    }

    private static func testDestinationParentReplacementCannotEscape(
        root: URL
    ) throws {
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("parent-race-source")
        let destination = root.appendingPathComponent("parent-race-destination")
        let outside = root.appendingPathComponent("parent-race-outside")
        try createSource(at: source)
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideSentinel = outside.appendingPathComponent("config.json")
        try Data("outside".utf8).write(to: outsideSentinel)
        let migrator = SourceDataMigrator(
            candidateRootURLs: [source],
            faultInjector: { point in
                guard point == .afterTargetRename(0) else {
                    return
                }
                let config = destination.appendingPathComponent("config")
                try fileManager.moveItem(
                    at: config,
                    to: destination.appendingPathComponent("config-replaced")
                )
                try fileManager.createSymbolicLink(at: config, withDestinationURL: outside)
            }
        )
        do {
            _ = try migrator.import(
                candidate: try requireCandidate(migrator),
                destination: destination
            )
            throw TestFailure.assertion("replaced destination parent was accepted")
        } catch let error as SourceDataMigrationError {
            try require(
                error == .rollbackFailed,
                "wrong destination replacement error"
            )
        }
        let outsideAfter = try Data(contentsOf: outsideSentinel)
        try require(
            outsideAfter == Data("outside".utf8),
            "destination race escaped into an outside directory"
        )
    }

    private static func testRollbackRecoveryAtEveryDurabilityBoundary(
        root: URL
    ) throws {
        let points: [MigrationFaultPoint] = [
            .afterRollbackTemporaryFsync(0),
            .afterRollbackRename(0),
            .afterRollbackDirectoryFsync(0),
        ]
        for (index, rollbackPoint) in points.enumerated() {
            let source = root.appendingPathComponent(
                "rollback-crash-source-\(index)"
            )
            let destination = root.appendingPathComponent(
                "rollback-crash-destination-\(index)"
            )
            try createSource(at: source)
            try FileManager.default.createDirectory(
                at: destination.appendingPathComponent("config"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: destination.appendingPathComponent("data"),
                withIntermediateDirectories: true
            )
            try Data("old-config".utf8).write(
                to: destination.appendingPathComponent("config/config.json")
            )
            let baseline = try byteSnapshot(of: destination)
            let crashingImport = SourceDataMigrator(
                candidateRootURLs: [source],
                faultInjector: { point in
                    if point == .afterTargetRename(0) {
                        throw SimulatedMigrationCrash()
                    }
                }
            )
            do {
                _ = try crashingImport.import(
                    candidate: try requireCandidate(crashingImport),
                    destination: destination
                )
                throw TestFailure.assertion(
                    "rollback fixture import did not crash"
                )
            } catch is SimulatedMigrationCrash {
                // Expected.
            }
            let crashingRecovery = SourceDataMigrator(
                candidateRootURLs: [],
                faultInjector: { point in
                    if point == rollbackPoint {
                        throw SimulatedMigrationCrash()
                    }
                }
            )
            do {
                try crashingRecovery.recoverPendingImports(
                    destination: destination
                )
                throw TestFailure.assertion(
                    "rollback fault \(rollbackPoint) did not crash"
                )
            } catch is SimulatedMigrationCrash {
                // Expected.
            }
            try SourceDataMigrator(candidateRootURLs: [])
                .recoverPendingImports(destination: destination)
            let recovered = try byteSnapshot(of: destination)
                .filter { !$0.key.hasPrefix("backups") }
            let expected = baseline.filter { !$0.key.hasPrefix("backups") }
            try require(
                recovered == expected,
                "rollback crash did not recover to all-old"
            )
            try require(
                !recovered.keys.contains {
                    $0.contains(".migration-rollback-")
                },
                "rollback left a sensitive temporary file"
            )
        }
    }

    private static func testCrossProcessImportLock(root: URL) throws {
        let source = root.appendingPathComponent("lock-source")
        let destination = root.appendingPathComponent("lock-destination")
        try createSource(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(destination.path.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        let lockURL = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".mac-face-lock-migration-\(digest).lock"
            )
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        try require(fd >= 0, "could not create test migration lock")
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        try require(flock(fd, LOCK_EX | LOCK_NB) == 0, "could not hold test lock")
        let migrator = SourceDataMigrator(candidateRootURLs: [source])
        do {
            _ = try migrator.import(
                candidate: try requireCandidate(migrator),
                destination: destination
            )
            throw TestFailure.assertion("concurrent migration lock was ignored")
        } catch let error as SourceDataMigrationError {
            try require(error == .migrationInProgress, "wrong lock contention error")
        }
    }

    private static func testPayloadProvenanceIsRevalidated(root: URL) throws {
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("payload-provenance-source")
        let destination = root.appendingPathComponent(
            "payload-provenance-destination"
        )
        try createSource(at: source)
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        let migrator = SourceDataMigrator(candidateRootURLs: [source])
        let candidate = try requireCandidate(migrator)
        let config = source.appendingPathComponent("config/config.json")
        try fileManager.removeItem(at: config)
        try Data(
            "{\"mode\":\"presence_guard\",\"camera_index\":1}".utf8
        ).write(to: config)
        do {
            _ = try migrator.import(
                candidate: candidate,
                destination: destination
            )
            throw TestFailure.assertion(
                "valid replacement payload bypassed discovery binding"
            )
        } catch let error as SourceDataMigrationError {
            try require(
                error == .sourceChanged("config/config.json"),
                "replacement payload returned the wrong error"
            )
        }
    }

    private static func testDestinationRootReplacementKeepsOneLock(
        root: URL
    ) throws {
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("root-race-source")
        let destination = root.appendingPathComponent("root-race-destination")
        let detached = root.appendingPathComponent("root-race-detached")
        try createSource(at: source)
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        let baseline = try byteSnapshot(of: destination)
        var concurrentError: SourceDataMigrationError?
        let migrator = SourceDataMigrator(
            candidateRootURLs: [source],
            faultInjector: { point in
                guard point == .afterJournalDirectoryFsync("initial", -1)
                else {
                    return
                }
                try fileManager.moveItem(at: destination, to: detached)
                try fileManager.createDirectory(
                    at: destination.appendingPathComponent("config"),
                    withIntermediateDirectories: true
                )
                try fileManager.createDirectory(
                    at: destination.appendingPathComponent("data"),
                    withIntermediateDirectories: true
                )
                do {
                    let second = SourceDataMigrator(
                        candidateRootURLs: [source]
                    )
                    _ = try second.import(
                        candidate: try requireCandidate(second),
                        destination: destination
                    )
                } catch let error as SourceDataMigrationError {
                    concurrentError = error
                }
            }
        )
        do {
            _ = try migrator.import(
                candidate: try requireCandidate(migrator),
                destination: destination
            )
            throw TestFailure.assertion("replaced destination root was accepted")
        } catch let error as SourceDataMigrationError {
            try require(
                error == .rollbackFailed || error == .unsafeDestination("."),
                "wrong replaced-root error"
            )
        }
        try require(
            concurrentError == .migrationInProgress,
            "root replacement created an independent migration lock"
        )
        let replacementSnapshot = try byteSnapshot(of: destination)
        try require(
            replacementSnapshot == baseline,
            "replacement root was modified by an in-flight migration"
        )
    }

    private static func testUnknownTransactionsBlockRecovery(
        root: URL
    ) throws {
        let fileManager = FileManager.default
        for suffix in ["missing", "corrupt", "unknown-name"] {
            let destination = root.appendingPathComponent(
                "strict-journal-\(suffix)"
            )
            try fileManager.createDirectory(
                at: destination.appendingPathComponent("config"),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: destination.appendingPathComponent("data"),
                withIntermediateDirectories: true
            )
            let transactionName = suffix == "unknown-name"
                ? "import-not-a-uuid"
                : "import-\(UUID().uuidString.lowercased())"
            let transaction = destination
                .appendingPathComponent("backups")
                .appendingPathComponent(transactionName)
            try fileManager.createDirectory(
                at: transaction,
                withIntermediateDirectories: true
            )
            if suffix == "corrupt" {
                try Data("{}".utf8).write(
                    to: transaction.appendingPathComponent("journal.json")
                )
            }
            do {
                try SourceDataMigrator(candidateRootURLs: [])
                    .recoverPendingImports(destination: destination)
                throw TestFailure.assertion(
                    "unknown transaction \(suffix) was silently removed"
                )
            } catch let error as SourceDataMigrationError {
                try require(
                    error == .recoveryFailed,
                    "unknown transaction returned the wrong error"
                )
            }
            try require(
                fileManager.fileExists(atPath: transaction.path),
                "unknown transaction was deleted during failed recovery"
            )
        }

        let source = root.appendingPathComponent("strict-journal-source")
        let destination = root.appendingPathComponent(
            "strict-journal-inconsistent-complete"
        )
        try createSource(at: source)
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        let migrator = SourceDataMigrator(candidateRootURLs: [source])
        let result = try migrator.import(
            candidate: try requireCandidate(migrator),
            destination: destination
        )
        let journalURL = result.backupURL.appendingPathComponent("journal.json")
        var journal = try JSONSerialization.jsonObject(
            with: Data(contentsOf: journalURL)
        ) as! [String: Any]
        journal["committed_count"] = 0
        try JSONSerialization.data(
            withJSONObject: journal,
            options: [.sortedKeys]
        ).write(to: journalURL)
        do {
            try SourceDataMigrator(candidateRootURLs: [])
                .recoverPendingImports(destination: destination)
            throw TestFailure.assertion(
                "inconsistent complete transaction suppressed recovery"
            )
        } catch let error as SourceDataMigrationError {
            try require(
                error == .recoveryFailed,
                "inconsistent complete transaction returned the wrong error"
            )
        }
        try require(
            fileManager.fileExists(atPath: result.backupURL.path),
            "inconsistent complete transaction was deleted"
        )
    }

    private static func testReorderedNumpyHeaderUsesSharedValidator(
        root: URL
    ) throws {
        let source = root.appendingPathComponent("reordered-npy-source")
        try createSource(at: source)
        let header = "{'shape': (2, 9216), 'fortran_order': False, 'descr': '<f4', }"
        try numpyContainer(header: header, rows: 2).write(
            to: source.appendingPathComponent("data/owner_face.npy")
        )
        let destination = root.appendingPathComponent("reordered-npy-destination")
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        let migrator = SourceDataMigrator(candidateRootURLs: [source])
        _ = try migrator.import(
            candidate: try requireCandidate(migrator),
            destination: destination
        )
    }

    private static func testLaunchAgentProvenanceIsExactAndRevalidated(
        root: URL
    ) throws {
        let fileManager = FileManager.default
        let source = root.appendingPathComponent("provenance-source")
        let launchAgents = root.appendingPathComponent("provenance-launchagents")
        try createSource(at: source)
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plistURL = launchAgents.appendingPathComponent(
            "com.wuyi.mac-face-lock-agent.plist"
        )
        func plist(arguments: [String], label: String) throws -> Data {
            try PropertyListSerialization.data(
                fromPropertyList: [
                    "Label": label,
                    "ProgramArguments": arguments,
                    "WorkingDirectory": source.path,
                ],
                format: .xml,
                options: 0
            )
        }
        let executable = source.appendingPathComponent(
            "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
        ).path
        try plist(
            arguments: [executable, source.path, root.path],
            label: "com.wuyi.mac-face-lock-agent"
        ).write(to: plistURL)
        let migrator = SourceDataMigrator(
            launchAgentDirectoryURL: launchAgents
        )
        try require(
            migrator.discoverCandidates().isEmpty,
            "arbitrary extra absolute LaunchAgent argument was trusted"
        )

        try plist(
            arguments: [executable, source.path],
            label: "com.wuyi.mac-face-lock-agent"
        ).write(to: plistURL)
        guard let candidate = migrator.discoverCandidates().first else {
            throw TestFailure.assertion("exact known LaunchAgent schema was not discovered")
        }
        try plist(
            arguments: [executable, source.path],
            label: "changed-after-selection"
        ).write(to: plistURL)
        let destination = root.appendingPathComponent("provenance-destination")
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destination.appendingPathComponent("data"),
            withIntermediateDirectories: true
        )
        do {
            _ = try migrator.import(candidate: candidate, destination: destination)
            throw TestFailure.assertion("changed LaunchAgent provenance was accepted")
        } catch let error as SourceDataMigrationError {
            try require(
                error == .candidateProvenanceChanged,
                "wrong changed-provenance error"
            )
        }
    }

    private static func numpyContainer(header rawHeader: String, rows: Int) -> Data {
        var header = rawHeader
        let padding = (64 - ((10 + header.utf8.count + 1) % 64)) % 64
        header += String(repeating: " ", count: padding) + "\n"
        var data = Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59, 0x01, 0x00])
        let length = UInt16(header.utf8.count)
        data.append(UInt8(length & 0xff))
        data.append(UInt8(length >> 8))
        data.append(Data(header.utf8))
        let one = Float(1).bitPattern.littleEndian
        for _ in 0..<(rows * 9_216) {
            var bits = one
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }
}

private struct SimulatedMigrationCrash: MigrationCrashFault {}
