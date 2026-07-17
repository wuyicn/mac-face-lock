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
            afterCommit: { committedCount in
                if committedCount == 2 {
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
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
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
        let candidate = try requireCandidate(fifoMigrator)
        let destination = root.appendingPathComponent("fifo-destination")
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            _ = try fifoMigrator.import(candidate: candidate, destination: destination)
            throw TestFailure.assertion("special source file was accepted")
        } catch let error as SourceDataMigrationError {
            try require(
                error == .unsafeSourceEntry("data/ui-preferences.json"),
                "special source file returned the wrong error"
            )
        }
    }
}
