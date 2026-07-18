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
        try testRootIdentityMismatchBlocksRemoval()
        print("Secure file tree tests passed")
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
            try require(
                FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("data/state.json").path
                ),
                "replacement was removed after identity mismatch"
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
