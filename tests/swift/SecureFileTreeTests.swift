import Darwin
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure.assertion(message)
    }
}

private struct SecureTreeFixture {
    let home: URL
    let root: URL
    let outside: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mac-face-lock-secure-tree-\(UUID().uuidString)",
                isDirectory: true
            )
        root = home.appendingPathComponent("legacy", isDirectory: true)
        outside = home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
    }

    func write(_ relativePath: String, bytes: [UInt8]) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(bytes).write(to: url)
    }

    func makeDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relativePath),
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

@main
struct SecureFileTreeTests {
    static func main() throws {
        try testUnlinkFlagsRemainCompatibleWithOlderDarwinSDKs()
        try testReadsPreflightsAndRemovesOrdinaryTree()
        try testEmptyAndMissingTargets()
        try testRejectsInvalidRelativePaths()
        try testRejectsUnsafeEntriesBeforeDeletion()
        try testRejectsHardLinks()
        try testRejectsSpecialFiles()
        try testRejectsWrongOwner()
        try testRejectsInvalidRoots()
        try testRejectsSymlinkBetweenAncestorAndRoot()
        try testEnforcesEntryAndByteBudgets()
        try testReadLimitIsEnforced()
        try testIdentityReplacementBlocksRemoval()
        try testReplacementInsideFinalWindowIsNotDeleted()
        try testFinalTombstoneChildReplacementSurvives()
        try testFinalTombstoneRootReplacementSurvives()
        try testInterruptedTombstoneIsRecoveredSafely()
        try testInterruptedFilePurgeIsRecoveredByFreshTree()
        try testInterruptedDirectoryPurgeIsRecoveredByFreshTree()
        try testChangedPurgeReplacementSurvivesRecovery()
        try testRecoveryDoesNotSweepUnjournaledPurgeNames()
        try testInPlaceMutationBlocksRemoval()
        try testDescriptorBoundAtomicFileRoundTrip()
        try testDescriptorBoundWriteRejectsUnsafeNames()
        try testDescriptorBoundWriteRejectsDestinationReplacement()
        try testDescriptorBoundWriteRejectsRootReplacement()
        try testDescriptorBoundReadRejectsABASwap()
        try testRootPathReplacementBlocksRemoval()
        try testRootIdentityMismatchBlocksRemoval()
        print("Secure file tree tests passed")
    }

    private static func testUnlinkFlagsRemainCompatibleWithOlderDarwinSDKs() throws {
        try require(
            SecureRemovalFlags.unlinkFlags(
                kind: .file,
                operatingSystemMajorVersion: 15
            ) == 0,
            "older macOS file removal used unsupported unlinkat flags"
        )
        try require(
            SecureRemovalFlags.unlinkFlags(
                kind: .directory,
                operatingSystemMajorVersion: 15
            ) == AT_REMOVEDIR,
            "older macOS directory removal lost AT_REMOVEDIR compatibility"
        )
        try require(
            SecureRemovalFlags.unlinkFlags(
                kind: .file,
                operatingSystemMajorVersion: 26
            ) == 0xC000,
            "macOS 26 file removal lost busy/link-count defenses"
        )
        try require(
            SecureRemovalFlags.unlinkFlags(
                kind: .directory,
                operatingSystemMajorVersion: 26
            ) == (AT_REMOVEDIR | 0x4000),
            "macOS 26 directory removal used the wrong defense flags"
        )
    }

    private static func makeTree(_ fixture: SecureTreeFixture) throws -> SecureFileTree {
        try SecureFileTree(
            rootURL: fixture.root,
            requiredAncestorURL: fixture.home,
            requiredOwner: getuid()
        )
    }

    private static func testReadsPreflightsAndRemovesOrdinaryTree() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/nested/state.json", bytes: [0x7B, 0x7D])
        try fixture.makeDirectory("logs/empty")
        try fixture.write("keep.txt", bytes: [9])
        let tree = try makeTree(fixture)

        let contents = try tree.readRegularFile("data/nested/state.json", maximumBytes: 2)
        try require(contents == Data([0x7B, 0x7D]), "regular file contents changed")

        let manifest = try tree.preflight(
            relativeTargets: ["data", "logs"],
            budget: .legacyCleanup
        )
        try require(
            manifest.rootIdentity == tree.rootIdentity,
            "manifest did not bind the trusted root identity"
        )
        try require(
            manifest.entriesDeepestFirst.map(\.relativePath)
                == [
                    "data/nested/state.json",
                    "data/nested",
                    "logs/empty",
                    "data",
                    "logs",
                ],
            "manifest was not deterministic and deepest-first: "
                + "\(manifest.entriesDeepestFirst.map(\.relativePath))"
        )

        try tree.remove(manifest)

        try require(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("data").path
            ),
            "preflighted data target was not removed"
        )
        try require(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("logs").path
            ),
            "preflighted logs target was not removed"
        )
        try require(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("keep.txt").path
            ),
            "removal touched an unlisted target"
        )
        try tree.remove(manifest)
    }

    private static func testEmptyAndMissingTargets() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("keep.txt", bytes: [1])
        let tree = try makeTree(fixture)

        let empty = try tree.preflight(relativeTargets: [], budget: .legacyCleanup)
        try require(empty.entriesDeepestFirst.isEmpty, "empty target list produced entries")

        let missing = try tree.preflight(
            relativeTargets: ["missing", "also/missing"],
            budget: .legacyCleanup
        )
        try require(missing.entriesDeepestFirst.isEmpty, "missing targets produced entries")
        try tree.remove(missing)
        try require(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("keep.txt").path
            ),
            "missing-target removal changed the tree"
        )
    }

    private static func testRejectsInvalidRelativePaths() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/state.json", bytes: [1])
        let tree = try makeTree(fixture)

        for path in ["", "/data", ".", "..", "data/.", "data/..", "data//state.json"] {
            do {
                _ = try tree.preflight(
                    relativeTargets: [path],
                    budget: .legacyCleanup
                )
                throw TestFailure.assertion("invalid relative path was accepted: \(path)")
            } catch SecureFileTreeError.invalidRelativePath(path) {
                continue
            }
        }

        do {
            _ = try tree.preflight(
                relativeTargets: ["data", "data"],
                budget: .legacyCleanup
            )
            throw TestFailure.assertion("duplicate normalized target was accepted")
        } catch SecureFileTreeError.invalidRelativePath("data") {
            // Expected.
        }
    }

    private static func testRejectsUnsafeEntriesBeforeDeletion() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/owner_face.npy", bytes: [1, 2, 3])
        try fixture.makeDirectory("logs")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("logs/escape"),
            withDestinationURL: fixture.outside
        )

        let tree = try makeTree(fixture)
        do {
            _ = try tree.preflight(
                relativeTargets: ["data", "logs"],
                budget: .legacyCleanup
            )
            throw TestFailure.assertion("symlink tree passed preflight")
        } catch SecureFileTreeError.symbolicLink("logs/escape") {
            try require(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("data/owner_face.npy").path
                ),
                "failed preflight mutated an allowed target"
            )
        }
    }

    private static func testRejectsHardLinks() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/state.json", bytes: [1])
        let original = fixture.root.appendingPathComponent("data/state.json").path
        let alias = fixture.root.appendingPathComponent("data/state.alias").path
        guard link(original, alias) == 0 else {
            throw TestFailure.assertion("could not create hard-link fixture: \(errno)")
        }

        do {
            _ = try makeTree(fixture).preflight(
                relativeTargets: ["data"],
                budget: .legacyCleanup
            )
            throw TestFailure.assertion("hard-linked file passed preflight")
        } catch let error as SecureFileTreeError {
            switch error {
            case .hardLink("data/state.alias"), .hardLink("data/state.json"):
                break
            default:
                throw TestFailure.assertion("unexpected hard-link error: \(error)")
            }
        }
    }

    private static func testRejectsSpecialFiles() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.makeDirectory("logs")
        let fifo = fixture.root.appendingPathComponent("logs/events.fifo").path
        guard mkfifo(fifo, 0o600) == 0 else {
            throw TestFailure.assertion("could not create FIFO fixture: \(errno)")
        }

        do {
            _ = try makeTree(fixture).preflight(
                relativeTargets: ["logs"],
                budget: .legacyCleanup
            )
            throw TestFailure.assertion("FIFO passed preflight")
        } catch SecureFileTreeError.specialFile("logs/events.fifo") {
            // Expected.
        }
    }

    private static func testRejectsWrongOwner() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        let impossibleOwner = getuid() == uid_t.max ? getuid() - 1 : getuid() + 1

        do {
            _ = try SecureFileTree(
                rootURL: fixture.root,
                requiredAncestorURL: fixture.home,
                requiredOwner: impossibleOwner
            )
            throw TestFailure.assertion("wrong-owner root was accepted")
        } catch SecureFileTreeError.ownerMismatch(let path) {
            try require(path == fixture.root.path, "wrong-owner error named \(path)")
        }
    }

    private static func testRejectsInvalidRoots() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }

        for root in [fixture.home, fixture.outside.appendingPathComponent("../legacy")] {
            do {
                _ = try SecureFileTree(
                    rootURL: root,
                    requiredAncestorURL: fixture.home,
                    requiredOwner: getuid()
                )
                throw TestFailure.assertion("non-strict or non-normal root was accepted")
            } catch SecureFileTreeError.invalidRoot {
                continue
            }
        }

        let relativeRoot = URL(fileURLWithPath: "legacy", isDirectory: true)
        do {
            _ = try SecureFileTree(
                rootURL: relativeRoot,
                requiredAncestorURL: fixture.home,
                requiredOwner: getuid()
            )
            throw TestFailure.assertion("relative root was accepted")
        } catch SecureFileTreeError.invalidRoot {
            // Expected.
        }
    }

    private static func testRejectsSymlinkBetweenAncestorAndRoot() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        let actual = fixture.home.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        let alias = fixture.home.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let aliasedRoot = alias.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actual.appendingPathComponent("legacy"),
            withIntermediateDirectories: false
        )

        do {
            _ = try SecureFileTree(
                rootURL: aliasedRoot,
                requiredAncestorURL: fixture.home,
                requiredOwner: getuid()
            )
            throw TestFailure.assertion("symlinked root ancestor was accepted")
        } catch SecureFileTreeError.symbolicLink("alias") {
            // Expected.
        }
    }

    private static func testEnforcesEntryAndByteBudgets() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/one", bytes: [1, 2])
        try fixture.write("data/two", bytes: [3, 4])
        let tree = try makeTree(fixture)

        do {
            _ = try tree.preflight(
                relativeTargets: ["data"],
                budget: SecureTreeBudget(maximumEntries: 2, maximumLogicalBytes: 4)
            )
            throw TestFailure.assertion("entry budget overflow was accepted")
        } catch SecureFileTreeError.entryBudgetExceeded {
            // Expected.
        }

        do {
            _ = try tree.preflight(
                relativeTargets: ["data"],
                budget: SecureTreeBudget(maximumEntries: 3, maximumLogicalBytes: 3)
            )
            throw TestFailure.assertion("byte budget overflow was accepted")
        } catch SecureFileTreeError.byteBudgetExceeded {
            // Expected.
        }
    }

    private static func testReadLimitIsEnforced() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/state.json", bytes: [1, 2, 3])
        let tree = try makeTree(fixture)

        do {
            _ = try tree.readRegularFile("data/state.json", maximumBytes: 2)
            throw TestFailure.assertion("oversized regular file was read")
        } catch SecureFileTreeError.byteBudgetExceeded {
            // Expected.
        }
    }

    private static func testIdentityReplacementBlocksRemoval() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/state.json", bytes: [0x7B, 0x7D])
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["data"],
            budget: .legacyCleanup
        )
        try FileManager.default.removeItem(
            at: fixture.root.appendingPathComponent("data/state.json")
        )
        try fixture.write("data/state.json", bytes: [0x30])

        do {
            try tree.remove(manifest)
            throw TestFailure.assertion("replacement was deleted")
        } catch SecureFileTreeError.identityChanged("data/state.json") {
            let privateReplacement = try FileManager.default
                .contentsOfDirectory(
                    at: fixture.root,
                    includingPropertiesForKeys: nil
                )
                .first {
                    $0.lastPathComponent.hasPrefix(
                        ".mac-face-lock-delete-"
                    )
                }?
                .appendingPathComponent("state.json")
            try require(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("data/state.json").path
                ) || (
                    privateReplacement.map {
                        FileManager.default.fileExists(atPath: $0.path)
                    } ?? false
                ),
                "replacement was removed after identity mismatch"
            )
        }
    }

    private static func testReplacementInsideFinalWindowIsNotDeleted() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/state.json", bytes: [1])
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["data/state.json"],
            budget: .legacyCleanup
        )
        let tombstones = try tree.makeTombstones(
            manifest: manifest,
            relativeTargets: ["data/state.json"],
            nonce: { "race" }
        )
        let original = fixture.root.appendingPathComponent("data/state.json")
        do {
            try tree.remove(
                manifest,
                tombstones: tombstones,
                beforeRename: { _ in
                    try FileManager.default.removeItem(at: original)
                    try fixture.write("data/state.json", bytes: [9])
                }
            )
            throw TestFailure.assertion("unmanifested replacement was deleted")
        } catch SecureFileTreeError.identityChanged {
            let moved = fixture.root.appendingPathComponent(
                tombstones[0].tombstoneRelativePath
            )
            try require(
                FileManager.default.fileExists(atPath: moved.path),
                "unmanifested inode was deleted after atomic rename"
            )
            let movedData = try Data(contentsOf: moved)
            try require(
                movedData == Data([9]),
                "moved unmanifested inode contents changed"
            )
        }
    }

    private static func testInterruptedTombstoneIsRecoveredSafely() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("logs/event.json", bytes: [7])
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["logs"],
            budget: .legacyCleanup
        )
        let tombstones = try tree.makeTombstones(
            manifest: manifest,
            relativeTargets: ["logs"],
            nonce: { "interrupted" }
        )
        do {
            try tree.remove(
                manifest,
                tombstones: tombstones,
                afterRename: { _ in
                    throw TestFailure.assertion("simulated interruption")
                }
            )
            throw TestFailure.assertion("interruption did not stop removal")
        } catch TestFailure.assertion("simulated interruption") {
            // Expected.
        }
        try require(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(
                    tombstones[0].tombstoneRelativePath
                ).path
            ),
            "interrupted tombstone was lost"
        )

        try tree.recoverTombstones(tombstones, budget: .legacyCleanup)
        try require(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(
                    tombstones[0].tombstoneRelativePath
                ).path
            ),
            "safe retry did not remove the verified tombstone"
        )
    }

    private static func testInterruptedFilePurgeIsRecoveredByFreshTree() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("config/config.json", bytes: [1, 2, 3])
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["config/config.json"],
            budget: .legacyCleanup
        )
        let tombstones = try tree.makeTombstones(
            manifest: manifest,
            relativeTargets: ["config/config.json"],
            nonce: { "file-tombstone" },
            purgeNonce: { "file-purge" }
        )
        guard let purge = tombstones.first?.purges.first else {
            throw TestFailure.assertion("file purge was not journal-derived")
        }

        do {
            try tree.remove(
                manifest,
                tombstones: tombstones,
                afterFinalRename: { moved in
                    guard moved == purge else {
                        return
                    }
                    throw TestFailure.assertion("file purge interruption")
                }
            )
            throw TestFailure.assertion("file purge interruption was ignored")
        } catch TestFailure.assertion("file purge interruption") {
            // Simulated crash after rename and parent fsync.
        }
        try require(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(
                    purge.purgeRelativePath
                ).path
            ),
            "durable file purge path was not retained"
        )

        let freshTree = try makeTree(fixture)
        try freshTree.recoverTombstones(
            tombstones,
            budget: .legacyCleanup
        )
        try require(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(
                    purge.purgeRelativePath
                ).path
            ),
            "fresh-tree retry did not delete the validated file purge"
        )
    }

    private static func testInterruptedDirectoryPurgeIsRecoveredByFreshTree() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.makeDirectory("logs")
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["logs"],
            budget: .legacyCleanup
        )
        let tombstones = try tree.makeTombstones(
            manifest: manifest,
            relativeTargets: ["logs"],
            nonce: { "directory-tombstone" },
            purgeNonce: { "directory-purge" }
        )
        guard let purge = tombstones.first?.purges.first,
              purge.kind == .directory else {
            throw TestFailure.assertion("directory purge was not journal-derived")
        }

        do {
            try tree.remove(
                manifest,
                tombstones: tombstones,
                afterFinalRename: { moved in
                    guard moved == purge else {
                        return
                    }
                    throw TestFailure.assertion("directory purge interruption")
                }
            )
            throw TestFailure.assertion("directory purge interruption was ignored")
        } catch TestFailure.assertion("directory purge interruption") {
            // Simulated crash after rename and parent fsync.
        }

        let freshTree = try makeTree(fixture)
        try freshTree.recoverTombstones(
            tombstones,
            budget: .legacyCleanup
        )
        try require(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(
                    purge.purgeRelativePath
                ).path
            ),
            "fresh-tree retry did not delete the validated directory purge"
        )
    }

    private static func testChangedPurgeReplacementSurvivesRecovery() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("config/config.json", bytes: [1])
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["config/config.json"],
            budget: .legacyCleanup
        )
        let tombstones = try tree.makeTombstones(
            manifest: manifest,
            relativeTargets: ["config/config.json"],
            nonce: { "changed-tombstone" },
            purgeNonce: { "changed-purge" }
        )
        guard let purge = tombstones.first?.purges.first else {
            throw TestFailure.assertion("changed purge fixture is missing")
        }
        do {
            try tree.remove(
                manifest,
                tombstones: tombstones,
                afterFinalRename: { _ in
                    throw TestFailure.assertion("changed purge interruption")
                }
            )
        } catch TestFailure.assertion("changed purge interruption") {
            // Expected.
        }
        let purgeURL = fixture.root.appendingPathComponent(
            purge.purgeRelativePath
        )
        try FileManager.default.removeItem(at: purgeURL)
        try Data([9]).write(to: purgeURL)

        do {
            try makeTree(fixture).recoverTombstones(
                tombstones,
                budget: .legacyCleanup
            )
            throw TestFailure.assertion("changed purge replacement was deleted")
        } catch SecureFileTreeError.identityChanged {
            let replacementData = try Data(contentsOf: purgeURL)
            try require(
                replacementData == Data([9]),
                "changed purge replacement did not survive"
            )
        }
    }

    private static func testRecoveryDoesNotSweepUnjournaledPurgeNames() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/state.json", bytes: [1])
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["data/state.json"],
            budget: .legacyCleanup
        )
        let tombstones = try tree.makeTombstones(
            manifest: manifest,
            relativeTargets: ["data/state.json"],
            nonce: { "bounded-tombstone" },
            purgeNonce: { "bounded-purge" }
        )
        let unrelated = fixture.root.appendingPathComponent(
            ".mac-face-lock-purge-unrelated"
        )
        try Data([7]).write(to: unrelated)

        try tree.remove(manifest, tombstones: tombstones)
        try makeTree(fixture).recoverTombstones(
            tombstones,
            budget: .legacyCleanup
        )

        let unrelatedData = try Data(contentsOf: unrelated)
        try require(
            unrelatedData == Data([7]),
            "recovery swept an unjournaled hidden purge name"
        )
    }

    private static func testFinalTombstoneChildReplacementSurvives() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/state.json", bytes: [1])
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["data"],
            budget: .legacyCleanup
        )
        let tombstones = try tree.makeTombstones(
            manifest: manifest,
            relativeTargets: ["data"],
            nonce: { "final-child" }
        )
        let movedChild = fixture.root.appendingPathComponent(
            tombstones[0].tombstoneRelativePath + "/state.json"
        )
        do {
            try tree.remove(
                manifest,
                tombstones: tombstones,
                beforeFinalRemoval: { entry in
                    guard entry.relativePath
                        == tombstones[0].tombstoneRelativePath + "/state.json" else {
                        return
                    }
                    try FileManager.default.removeItem(at: movedChild)
                    try Data([9]).write(to: movedChild)
                }
            )
            throw TestFailure.assertion(
                "final child replacement was deleted"
            )
        } catch SecureFileTreeError.identityChanged {
            try require(
                FileManager.default.fileExists(atPath: movedChild.path),
                "final child replacement did not survive"
            )
            let replacement = try Data(contentsOf: movedChild)
            try require(
                replacement == Data([9]),
                "final child replacement contents changed"
            )
        }
    }

    private static func testFinalTombstoneRootReplacementSurvives() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.makeDirectory("logs")
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["logs"],
            budget: .legacyCleanup
        )
        let tombstones = try tree.makeTombstones(
            manifest: manifest,
            relativeTargets: ["logs"],
            nonce: { "final-root" }
        )
        let movedRoot = fixture.root.appendingPathComponent(
            tombstones[0].tombstoneRelativePath
        )
        let sentinel = movedRoot.appendingPathComponent("unmanifested.txt")
        do {
            try tree.remove(
                manifest,
                tombstones: tombstones,
                beforeFinalRemoval: { entry in
                    guard entry.relativePath
                        == tombstones[0].tombstoneRelativePath else {
                        return
                    }
                    try FileManager.default.removeItem(at: movedRoot)
                    try FileManager.default.createDirectory(
                        at: movedRoot,
                        withIntermediateDirectories: false
                    )
                    try Data([7]).write(to: sentinel)
                }
            )
            throw TestFailure.assertion(
                "final root replacement was deleted"
            )
        } catch SecureFileTreeError.identityChanged {
            try require(
                FileManager.default.fileExists(atPath: sentinel.path),
                "final root replacement did not survive"
            )
            let replacement = try Data(contentsOf: sentinel)
            try require(
                replacement == Data([7]),
                "final root replacement contents changed"
            )
        }
    }

    private static func testInPlaceMutationBlocksRemoval() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/state.json", bytes: [0x7B, 0x7D])
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["data/state.json"],
            budget: .legacyCleanup
        )
        try fixture.write(
            "data/state.json",
            bytes: Array(repeating: 0x41, count: 37)
        )

        do {
            try tree.remove(manifest)
            throw TestFailure.assertion("in-place replacement was deleted")
        } catch SecureFileTreeError.identityChanged("data/state.json") {
            try require(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent(
                        "data/state.json"
                    ).path
                ),
                "in-place replacement was removed after metadata mismatch"
            )
        }
    }

    private static func testDescriptorBoundAtomicFileRoundTrip() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        let tree = try makeTree(fixture)
        let first = Data(#"{"phase":"confirmed"}"#.utf8)
        try tree.replaceFileAtomically(
            "journal.json",
            temporaryName: ".journal-first.tmp",
            data: first,
            maximumBytes: 64 * 1_024,
            mode: 0o600
        )
        let firstPersisted = try tree.loadValidatedFile(
            "journal.json",
            maximumBytes: 64 * 1_024,
            requiredMode: 0o600
        )
        try require(
            firstPersisted == first,
            "descriptor-bound file round trip changed bytes"
        )

        let second = Data(#"{"completed":true}"#.utf8)
        try tree.replaceFileAtomically(
            "journal.json",
            temporaryName: ".journal-second.tmp",
            data: second,
            maximumBytes: 64 * 1_024,
            mode: 0o600
        )
        let persisted = try tree.loadValidatedFile(
            "journal.json",
            maximumBytes: 64 * 1_024,
            requiredMode: 0o600
        )
        try require(persisted == second, "atomic replacement kept stale bytes")
        var metadata = stat()
        try require(
            lstat(fixture.root.appendingPathComponent("journal.json").path, &metadata) == 0
                && metadata.st_uid == getuid()
                && metadata.st_nlink == 1
                && metadata.st_mode & 0o777 == 0o600,
            "atomic destination metadata was unsafe"
        )
    }

    private static func testDescriptorBoundWriteRejectsUnsafeNames() throws {
        do {
            let fixture = try SecureTreeFixture()
            defer { fixture.remove() }
            let external = fixture.outside.appendingPathComponent("journal")
            try Data("outside".utf8).write(to: external)
            try FileManager.default.createSymbolicLink(
                at: fixture.root.appendingPathComponent("journal.json"),
                withDestinationURL: external
            )
            let tree = try makeTree(fixture)

            do {
                try tree.replaceFileAtomically(
                    "journal.json",
                    temporaryName: ".journal.tmp",
                    data: Data("new".utf8),
                    maximumBytes: 64 * 1_024,
                    mode: 0o600
                )
                throw TestFailure.assertion("symlink destination was replaced")
            } catch is SecureFileTreeError {
                let externalContents = try String(
                    contentsOf: external,
                    encoding: .utf8
                )
                try require(
                    externalContents == "outside",
                    "symlink destination escaped the retained directory"
                )
            }
        }

        do {
            let fixture = try SecureTreeFixture()
            defer { fixture.remove() }
            try fixture.write("journal.json", bytes: [1])
            let alias = fixture.root.appendingPathComponent("journal.alias")
            guard link(
                fixture.root.appendingPathComponent("journal.json").path,
                alias.path
            ) == 0 else {
                throw TestFailure.assertion("could not create journal hard link")
            }
            let tree = try makeTree(fixture)
            do {
                try tree.replaceFileAtomically(
                    "journal.json",
                    temporaryName: ".journal.tmp",
                    data: Data([2]),
                    maximumBytes: 64 * 1_024,
                    mode: 0o600
                )
                throw TestFailure.assertion("hard-link destination was replaced")
            } catch SecureFileTreeError.hardLink("journal.json") {
                let aliasContents = try Data(contentsOf: alias)
                try require(
                    aliasContents == Data([1]),
                    "hard-linked destination was changed"
                )
            }
        }

        do {
            let fixture = try SecureTreeFixture()
            defer { fixture.remove() }
            try fixture.write(".journal.tmp", bytes: [7])
            let tree = try makeTree(fixture)
            do {
                try tree.replaceFileAtomically(
                    "journal.json",
                    temporaryName: ".journal.tmp",
                    data: Data([8]),
                    maximumBytes: 64 * 1_024,
                    mode: 0o600
                )
                throw TestFailure.assertion("pre-existing temporary file was reused")
            } catch SecureFileTreeError.systemCall("openat", ".journal.tmp", EEXIST) {
                let temporaryContents = try Data(
                    contentsOf: fixture.root.appendingPathComponent(".journal.tmp")
                )
                try require(
                    temporaryContents == Data([7]),
                    "pre-existing temporary file was changed"
                )
            }
        }
    }

    private static func testDescriptorBoundWriteRejectsRootReplacement() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        let tree = try makeTree(fixture)
        let displaced = fixture.home.appendingPathComponent(
            "displaced-support",
            isDirectory: true
        )

        do {
            try tree.replaceFileAtomically(
                "journal.json",
                temporaryName: ".journal.tmp",
                data: Data("secret".utf8),
                maximumBytes: 64 * 1_024,
                mode: 0o600,
                beforeRename: {
                    try FileManager.default.moveItem(
                        at: fixture.root,
                        to: displaced
                    )
                    try FileManager.default.createDirectory(
                        at: fixture.root,
                        withIntermediateDirectories: false
                    )
                    try FileManager.default.removeItem(at: fixture.root)
                    try FileManager.default.moveItem(
                        at: displaced,
                        to: fixture.root
                    )
                }
            )
            throw TestFailure.assertion("support root A-B-A replacement was accepted")
        } catch SecureFileTreeError.identityChanged {
            try require(
                !FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("journal.json").path
                ),
                "root replacement published the journal"
            )
        }
    }

    private static func testDescriptorBoundWriteRejectsDestinationReplacement()
        throws
    {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        let tree = try makeTree(fixture)
        let journal = fixture.root.appendingPathComponent("journal.json")
        let attacker = fixture.root.appendingPathComponent("attacker.json")
        try tree.replaceFileAtomically(
            "journal.json",
            temporaryName: ".journal-first.tmp",
            data: Data("trusted".utf8),
            maximumBytes: 64 * 1_024,
            mode: 0o600
        )

        do {
            try tree.replaceFileAtomically(
                "journal.json",
                temporaryName: ".journal-second.tmp",
                data: Data("new".utf8),
                maximumBytes: 64 * 1_024,
                mode: 0o600,
                beforeRename: {
                    try Data("attacker".utf8).write(to: attacker)
                    guard chmod(attacker.path, 0o600) == 0 else {
                        throw TestFailure.assertion(
                            "could not set attacker journal mode"
                        )
                    }
                    try FileManager.default.removeItem(at: journal)
                    try FileManager.default.moveItem(at: attacker, to: journal)
                }
            )
            throw TestFailure.assertion(
                "destination replacement before rename was accepted"
            )
        } catch SecureFileTreeError.identityChanged("journal.json") {
            let persisted = try String(contentsOf: journal, encoding: .utf8)
            try require(
                persisted == "attacker",
                "destination replacement fixture was not preserved"
            )
        }

        try tree.replaceFileAtomically(
            "journal.json",
            temporaryName: ".journal-third.tmp",
            data: Data("trusted-again".utf8),
            maximumBytes: 64 * 1_024,
            mode: 0o600
        )
        let saved = fixture.root.appendingPathComponent("journal.saved")
        do {
            try tree.replaceFileAtomically(
                "journal.json",
                temporaryName: ".journal-fourth.tmp",
                data: Data("new-again".utf8),
                maximumBytes: 64 * 1_024,
                mode: 0o600,
                beforeRename: {
                    try FileManager.default.moveItem(at: journal, to: saved)
                    try Data("transient-attacker".utf8).write(to: journal)
                    try FileManager.default.removeItem(at: journal)
                    try FileManager.default.moveItem(at: saved, to: journal)
                }
            )
            throw TestFailure.assertion(
                "destination A-B-A replacement before rename was accepted"
            )
        } catch SecureFileTreeError.identityChanged(let path) {
            try require(
                path == "journal.json" || path == fixture.root.path,
                "destination A-B-A error named unexpected path \(path)"
            )
            let persisted = try String(contentsOf: journal, encoding: .utf8)
            try require(
                persisted == "trusted-again",
                "destination A-B-A fixture did not restore trusted bytes"
            )
        }
    }

    private static func testDescriptorBoundReadRejectsABASwap() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        let journal = fixture.root.appendingPathComponent("journal.json")
        try Data("trusted".utf8).write(to: journal)
        guard chmod(journal.path, 0o600) == 0 else {
            throw TestFailure.assertion("could not set journal mode")
        }
        let tree = try makeTree(fixture)
        let saved = fixture.root.appendingPathComponent("journal.saved")

        do {
            _ = try tree.loadValidatedFile(
                "journal.json",
                maximumBytes: 64 * 1_024,
                requiredMode: 0o600,
                afterOpen: {
                    try FileManager.default.moveItem(at: journal, to: saved)
                    try Data("attacker".utf8).write(to: journal)
                    try FileManager.default.removeItem(at: journal)
                    try FileManager.default.moveItem(at: saved, to: journal)
                }
            )
            throw TestFailure.assertion("journal A-B-A read swap was accepted")
        } catch SecureFileTreeError.identityChanged("journal.json") {
            let restored = try String(contentsOf: journal, encoding: .utf8)
            try require(
                restored == "trusted",
                "A-B-A fixture did not restore the original file"
            )
        }
    }

    private static func testRootPathReplacementBlocksRemoval() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/state.json", bytes: [1])
        let tree = try makeTree(fixture)
        let manifest = try tree.preflight(
            relativeTargets: ["data"],
            budget: .legacyCleanup
        )
        let displacedRoot = fixture.home.appendingPathComponent(
            "displaced-legacy",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.root, to: displacedRoot)
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: false
        )
        try fixture.write("data/replacement.json", bytes: [2])

        do {
            try tree.remove(manifest)
            throw TestFailure.assertion("root path replacement was accepted")
        } catch SecureFileTreeError.identityChanged(let path) {
            try require(path == fixture.root.path, "root replacement error named \(path)")
            try require(
                FileManager.default.fileExists(
                    atPath: displacedRoot.appendingPathComponent("data/state.json").path
                ),
                "displaced original tree was mutated after root replacement"
            )
            try require(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent(
                        "data/replacement.json"
                    ).path
                ),
                "replacement root was mutated after root replacement"
            )
        }
    }

    private static func testRootIdentityMismatchBlocksRemoval() throws {
        let fixture = try SecureTreeFixture()
        defer { fixture.remove() }
        try fixture.write("data/state.json", bytes: [1])
        let tree = try makeTree(fixture)
        let actual = try tree.preflight(
            relativeTargets: ["data"],
            budget: .legacyCleanup
        )
        let forged = SecureTreeManifest(
            rootIdentity: SecureFileIdentity(
                device: actual.rootIdentity.device,
                inode: actual.rootIdentity.inode &+ 1
            ),
            entriesDeepestFirst: actual.entriesDeepestFirst
        )

        do {
            try tree.remove(forged)
            throw TestFailure.assertion("root identity mismatch was accepted")
        } catch SecureFileTreeError.identityChanged(let path) {
            try require(path == fixture.root.path, "root identity error named \(path)")
            try require(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("data/state.json").path
                ),
                "root identity mismatch mutated the tree"
            )
        }
    }
}
