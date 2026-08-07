# Mac Face Lock One-Way Legacy Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit, irreversible release-onboarding gate that safely removes the known source-beta services and runtime data before installing the self-contained release service.

**Architecture:** A low-level `SecureFileTree` owns descriptor-relative, no-follow inspection and deletion. `LegacyInstallCleaner` owns versioned plist recognition, cleanup journaling, launchctl orchestration, and retry. `SetupCoordinator` exposes a small UI state machine and blocks every release-service operation until cleanup is not required or has completed.

**Tech Stack:** Swift 5.x, Foundation, Darwin POSIX APIs, SwiftUI, `launchctl`, Python `unittest`, GitHub Actions on macOS 15.

## Global Constraints

- Implement the confirmed design in `docs/superpowers/specs/2026-07-18-one-way-legacy-cleanup-design.md`.
- Keep the release target at Apple Silicon and macOS 12.0 or newer.
- Automatic import remains absent: do not restore `SourceDataMigrator` or read old face/config content for migration; cleanup success must require fresh enrollment (“重新录入本人”).
- Cleanup runs only when `AppEnvironment.mode == .release`; source mode must never clean itself.
- Require explicit customer confirmation before creating a cleanup journal, stopping services, or deleting files.
- Delete only `config/config.json`, `data/`, `logs/`, the three named app bundles under `dist/`, and the two named LaunchAgent plists.
- Preserve the source root, `.git`, `.worktrees`, `.venv`, source, scripts, docs, tests, configuration templates, and current release Application Support data.
- Never follow symlinks. Reject hard-linked regular files, special files, ownership mismatches, identity changes, more than 50,000 entries, or more than 20 GiB logical file data before mutation.
- Use the existing release Agent label `com.wuyi.mac-face-lock-agent`; remove and do not reinstall `com.wuyi.mac-face-lock-status`.
- No backup, rollback, source-service restoration, or downgrade path.
- On partial cleanup, keep protection and all release-service operations disabled; permit only validated idempotent retry.
- Do not publish to GitHub or create a public Release in this plan.

## File Structure

- Create `src/app/SecureFileTree.swift`: generic descriptor-relative file inspection and allowlisted removal; no Mac Face Lock product knowledge.
- Create `tests/swift/SecureFileTreeTests.swift`: filesystem safety, budget, identity-race, and preservation tests.
- Create `src/app/LegacyInstallCleaner.swift`: known plist schemas, release/source classification, journal, launchctl stop/verify, cleanup, and retry.
- Create `tests/swift/LegacyInstallCleanerTests.swift`: current/historical detection, consent boundary, successful cleanup, failure, and retry tests.
- Modify `src/app/SetupModels.swift`: add the cleanup-aware root-routing input.
- Modify `src/app/SetupCoordinator.swift`: publish cleanup state and gate release service calls.
- Modify `tests/swift/SetupCoordinatorTests.swift`: verify orchestration and the no-service-before-cleanup invariant.
- Modify `src/app/Views.swift`: route cleanup-required completed installs back to onboarding.
- Modify `src/app/OnboardingView.swift`: render inspect, confirm, cancel, ambiguous, cleaning, retry, and completed states.
- Modify `src/app/AppDelegate.swift`: inspect before the first live-readiness refresh and show the onboarding window when cleanup needs attention.
- Rename `tests/test_no_legacy_migration.py` to `tests/test_legacy_cleanup_policy.py`: retain the import-migration ban while permitting only the reviewed cleanup capabilities.
- Modify `tests/test_packaging.py`: assert the customer-facing one-way cleanup flow and absence of terminal instructions.
- Modify `.github/workflows/ci.yml`: compile and run the two new Swift test executables and include the cleaner in coordinator tests.
- Modify `README.md`: explain source-beta takeover, irreversible deletion scope, fresh enrollment, and uninstall non-restoration.
- Modify `docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md`: replace the superseded “old data remains” paragraph with the confirmed takeover rule.
- Modify `docs/superpowers/specs/2026-07-18-defer-source-beta-migration-design.md`: mark its preservation boundary as superseded while keeping automatic import deferred.

---

### Task 1: Descriptor-Relative Secure File Tree

**Files:**
- Create: `src/app/SecureFileTree.swift`
- Create: `tests/swift/SecureFileTreeTests.swift`
- Modify: `.github/workflows/ci.yml`
- Rename: `tests/test_no_legacy_migration.py` → `tests/test_legacy_cleanup_policy.py`

**Interfaces:**
- Consumes: current user UID, an absolute root URL, exact relative targets, and `SecureTreeBudget`.
- Produces:

```swift
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
    enum Kind: String, Codable, Sendable { case file, directory }
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
    init(
        rootURL: URL,
        requiredAncestorURL: URL,
        requiredOwner: uid_t
    ) throws
    var rootIdentity: SecureFileIdentity { get }
    func readRegularFile(_ relativePath: String, maximumBytes: Int) throws -> Data
    func preflight(
        relativeTargets: [String],
        budget: SecureTreeBudget
    ) throws -> SecureTreeManifest
    func remove(_ manifest: SecureTreeManifest) throws
}
```

- [ ] **Step 1: Write failing safety tests**

Add a real temporary-directory fixture and tests that exercise ordinary files, nested directories, empty/missing targets, symlinks, hard links, FIFO files, ownership/type checks where the local test runner permits them, entry/byte budgets, and replacement after preflight.

```swift
private static func testRejectsUnsafeEntriesBeforeDeletion() throws {
    let fixture = try SecureTreeFixture()
    defer { fixture.remove() }
    try fixture.write("data/owner_face.npy", bytes: [1, 2, 3])
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent("logs/escape"),
        withDestinationURL: fixture.outside
    )

    let tree = try SecureFileTree(
        rootURL: fixture.root,
        requiredAncestorURL: fixture.home,
        requiredOwner: getuid()
    )
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

private static func testIdentityReplacementBlocksRemoval() throws {
    let fixture = try SecureTreeFixture()
    defer { fixture.remove() }
    try fixture.write("data/state.json", bytes: [0x7B, 0x7D])
    let tree = try SecureFileTree(
        rootURL: fixture.root,
        requiredAncestorURL: fixture.home,
        requiredOwner: getuid()
    )
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
```

- [ ] **Step 2: Run the new test to verify it fails**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/SecureFileTree.swift tests/swift/SecureFileTreeTests.swift \
  -o /tmp/mac-face-lock-secure-tree-tests
```

Expected: FAIL because `src/app/SecureFileTree.swift` and its types do not exist.

- [ ] **Step 3: Implement secure traversal and removal**

Open the trusted ancestor with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`, require the root to be a strict lexical descendant, then resolve every relative root component with `openat(..., O_DIRECTORY | O_NOFOLLOW)`. Inspect entries with `fstatat(..., AT_SYMLINK_NOFOLLOW)`, enumerate with `fdopendir(dup(fd))` plus `readdir`, and delete with `unlinkat`. Add a test where an intermediate component between the ancestor and root is a symlink; initialization must reject it.

The critical no-follow helpers must have these checks:

```swift
private func checkedIdentity(
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

private func removeEntry(
    parentFD: Int32,
    name: String,
    entry: SecureTreeEntry
) throws {
    var current = stat()
    guard fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
        if errno == ENOENT { return }
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
```

Reject empty paths, absolute paths, `.` and `..` components, duplicate normalized targets, overflow in entry/byte accounting, and any root identity change. `remove(_:)` must process only `entriesDeepestFirst`.

- [ ] **Step 4: Run secure-tree tests**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/SecureFileTree.swift tests/swift/SecureFileTreeTests.swift \
  -o /tmp/mac-face-lock-secure-tree-tests &&
/tmp/mac-face-lock-secure-tree-tests
```

Expected: `Secure file tree tests passed`.

- [ ] **Step 5: Update policy and CI for the isolated capability**

Rename the policy test and change its capability allowlist so POSIX open/read/enumeration/deletion primitives are permitted only in `src/app/SecureFileTree.swift`. Keep `SourceDataMigrator`, import, recovery, backup, and migration actions forbidden.

Add this macOS CI step:

```yaml
- name: Run Swift secure-file-tree tests
  run: |
    xcrun swiftc -parse-as-library -DTESTING \
      src/app/SecureFileTree.swift tests/swift/SecureFileTreeTests.swift \
      -o "$RUNNER_TEMP/mac-face-lock-secure-tree-tests"
    "$RUNNER_TEMP/mac-face-lock-secure-tree-tests"
```

Run:

```bash
python3 -m unittest tests.test_legacy_cleanup_policy -v
```

Expected: PASS with the policy still rejecting a synthetic POSIX file reader placed in any other Swift source.

- [ ] **Step 6: Commit**

```bash
git add src/app/SecureFileTree.swift tests/swift/SecureFileTreeTests.swift \
  tests/test_legacy_cleanup_policy.py tests/test_no_legacy_migration.py \
  .github/workflows/ci.yml
git commit -m "feat: add secure legacy file tree"
```

---

### Task 2: Exact Legacy Install Detection

**Files:**
- Create: `src/app/LegacyInstallCleaner.swift`
- Create: `tests/swift/LegacyInstallCleanerTests.swift`
- Modify: `.github/workflows/ci.yml`
- Modify: `tests/test_legacy_cleanup_policy.py`

**Interfaces:**
- Consumes: `SecureFileTree`, current user home, release support URL, UID, and an injected `ServiceCommandRunning`.
- Produces:

```swift
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
```

- [ ] **Step 1: Write failing exact-schema tests**

Build plist fixtures with `PropertyListSerialization` and cover:

- both current source schemas;
- historical Agent `["<root>/.../MacFaceLockAgent", "-u", "agent.py"]`;
- historical Status `Mac Face Lock Status.app/.../MacFaceLockStatus`;
- no plists;
- a current release Agent plist without Status;
- only one source plist;
- mixed release Agent plus source Status;
- different roots;
- root outside the supplied home;
- unknown argument, field combination, external `PYTHONPATH`, symlink/hard-link plist, and plist larger than 1 MiB.

```swift
private static func testRecognizesInstalledHistoricalPair() throws {
    let fixture = try LegacyCleanerFixture()
    defer { fixture.remove() }
    try fixture.writeHistoricalAgentPlist()
    try fixture.writeUnifiedStatusPlist()

    let result = fixture.cleaner.inspect()
    guard case .confirmed(let candidate) = result else {
        throw TestFailure.assertion("historical source pair was not confirmed: \(result)")
    }
    try require(candidate.rootURL == fixture.legacyRoot, "wrong source root")
}

private static func testMixedReleaseAndSourcePairIsAmbiguous() throws {
    let fixture = try LegacyCleanerFixture()
    defer { fixture.remove() }
    try fixture.writeReleaseAgentPlist()
    try fixture.writeUnifiedStatusPlist()

    guard case .ambiguous = fixture.cleaner.inspect() else {
        throw TestFailure.assertion("mixed release/source pair was accepted")
    }
}
```

- [ ] **Step 2: Run the cleaner test to verify it fails**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/Models.swift src/app/ServiceManager.swift \
  src/app/SecureFileTree.swift src/app/LegacyInstallCleaner.swift \
  tests/swift/LegacyInstallCleanerTests.swift \
  -o /tmp/mac-face-lock-legacy-cleaner-tests
```

Expected: FAIL because `LegacyInstallCleaner.swift` and its public types do not exist.

- [ ] **Step 3: Implement exact versioned recognition**

Define exact constants and reject unknown combinations:

```swift
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
}
```

Parse plist data only through `SecureFileTree.readRegularFile`. Convert it with `PropertyListSerialization`, require a `[String: Any]`, and match one of four explicit source schemas. The release schema is accepted only when:

```swift
arguments == [
    appURL.appendingPathComponent(
        "Contents/Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
    ).path,
    "--resources-dir",
    appURL.appendingPathComponent("Contents/Resources").path,
    "--support-dir",
    supportURL.path,
    "agent",
]
```

For historical `PYTHONPATH`, accept only:

```swift
let prefix = candidateRoot
    .appendingPathComponent(".venv/lib", isDirectory: true).path + "/python"
let suffix = "/site-packages"
guard pythonPath.hasPrefix(prefix), pythonPath.hasSuffix(suffix),
      !pythonPath.dropFirst(prefix.count).dropLast(suffix.count).isEmpty else {
    return .ambiguous("旧版 PYTHONPATH 不属于已知源码环境。")
}
```

Return only customer-safe Chinese errors; do not include plist contents or biometric/config data.

- [ ] **Step 4: Run detection and policy tests**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/Models.swift src/app/ServiceManager.swift \
  src/app/SecureFileTree.swift src/app/LegacyInstallCleaner.swift \
  tests/swift/LegacyInstallCleanerTests.swift \
  -o /tmp/mac-face-lock-legacy-cleaner-tests &&
/tmp/mac-face-lock-legacy-cleaner-tests
python3 -m unittest tests.test_legacy_cleanup_policy -v
```

Expected: all detection tests pass; policy reports no unreviewed read/enumeration capability.

- [ ] **Step 5: Add the cleaner CI target**

```yaml
- name: Run Swift legacy-install-cleaner tests
  run: |
    xcrun swiftc -parse-as-library -DTESTING \
      src/app/Models.swift src/app/ServiceManager.swift \
      src/app/SecureFileTree.swift src/app/LegacyInstallCleaner.swift \
      tests/swift/LegacyInstallCleanerTests.swift \
      -o "$RUNNER_TEMP/mac-face-lock-legacy-cleaner-tests"
    "$RUNNER_TEMP/mac-face-lock-legacy-cleaner-tests"
```

Run a YAML parse check:

```bash
python3 - <<'PY'
from pathlib import Path
text = Path(".github/workflows/ci.yml").read_text()
assert "Run Swift legacy-install-cleaner tests" in text
assert "tests/swift/LegacyInstallCleanerTests.swift" in text
print("legacy cleaner CI target present")
PY
```

Expected: `legacy cleaner CI target present`.

- [ ] **Step 6: Commit**

```bash
git add src/app/LegacyInstallCleaner.swift \
  tests/swift/LegacyInstallCleanerTests.swift \
  tests/test_legacy_cleanup_policy.py .github/workflows/ci.yml
git commit -m "feat: detect known source beta installs"
```

---

### Task 3: Irreversible Cleanup, Journal, and Retry

**Files:**
- Modify: `src/app/LegacyInstallCleaner.swift`
- Modify: `tests/swift/LegacyInstallCleanerTests.swift`

**Interfaces:**
- Consumes: `LegacyCleanupCandidate` returned by Task 2.
- Produces:

```swift
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
```

- [ ] **Step 1: Write failing execution tests**

Add tests proving:

- `inspect()` alone performs no launchctl command and no write/delete;
- a full-preflight failure creates no journal, runs no launchctl command, and deletes nothing;
- `clean(_:)` creates a `0600` journal only after a confirmed candidate is supplied;
- Status is booted out before Agent;
- non-loaded jobs are accepted, but other command failures block deletion;
- every source target is removed and sentinel source/development files remain;
- plist removal happens after source-target removal;
- a failure after source deletion returns `.cleanupIncomplete`;
- retry validates the journal owner, mode, schema, root path, root identity, and fixed allowlist;
- retry is idempotent when some targets are already absent;
- tampered journal or changed root identity performs no deletion;
- successful cleanup leaves a completion marker without the old root path or target list;
- release Application Support data is preserved.

```swift
private static func testSuccessfulCleanupDeletesOnlyAllowlist() async throws {
    let fixture = try LegacyCleanerFixture()
    defer { fixture.remove() }
    try fixture.installKnownLegacyPairAndData()
    try fixture.write("README.md", "preserve")
    try fixture.write(".git/HEAD", "ref: refs/heads/main")
    try fixture.write(".venv/bin/python", "preserve")
    try fixture.write("dist/Other Tool.app/sentinel", "preserve")
    let candidate = try fixture.confirmedCandidate()

    let result = await fixture.cleaner.clean(candidate)

    try require(result == .notFound, "cleanup did not finish")
    let bootouts = fixture.commandRunner.calls
        .filter { $0.arguments.first == "bootout" }
        .map(\.arguments)
    try require(
        bootouts == [
            ["bootout", "gui/501/com.wuyi.mac-face-lock-status"],
            ["bootout", "gui/501/com.wuyi.mac-face-lock-agent"],
        ],
        "services stopped in the wrong order"
    )
    try fixture.requireAllowlistedTargetsAbsent()
    try fixture.requirePreserved("README.md")
    try fixture.requirePreserved(".git/HEAD")
    try fixture.requirePreserved(".venv/bin/python")
    try fixture.requirePreserved("dist/Other Tool.app/sentinel")
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/Models.swift src/app/ServiceManager.swift \
  src/app/SecureFileTree.swift src/app/LegacyInstallCleaner.swift \
  tests/swift/LegacyInstallCleanerTests.swift \
  -o /tmp/mac-face-lock-legacy-cleaner-tests &&
/tmp/mac-face-lock-legacy-cleaner-tests
```

Expected: FAIL in cleanup/journal assertions because Task 2 only detects.

- [ ] **Step 3: Implement the versioned journal**

Store the journal at:

```swift
supportURL.appendingPathComponent("legacy-cleanup-v1.json")
```

Create a sibling temporary file with `open(..., O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)`, write all encoded bytes with an EINTR-safe loop, call `fsync`, then atomically rename it. Reject a journal unless `lstat` reports current UID, regular file, link count 1, mode exactly `0600`, size no more than 64 KiB, schema 1, the exact fixed target list, and a root path inside the configured home.

The completion file must contain only:

```json
{"schema_version":1,"completed":true}
```

- [ ] **Step 4: Implement stop, verify, delete, and retry**

Use the existing bounded command runner:

```swift
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
        let suffix = bootout.exitCode == 0 ? "" : "（停止命令代码 \(bootout.exitCode)）"
        throw LegacyCleanupError.serviceStillLoaded(label + suffix)
    }
}
```

Execution must follow this exact phase order:

```swift
try preflightAllTargetsWithoutMutation(candidate)
try journalStore.save(candidate, phase: .confirmed)
try await stopAndVerify(LegacyIdentity.statusLabel)
try await stopAndVerify(LegacyIdentity.agentLabel)
try journalStore.advance(to: .servicesStopped)
try preflightAllRemainingTargetsWithoutMutation(candidate)
try removeSourceTargets(candidate)
try journalStore.advance(to: .sourceTargetsRemoved)
try removeLegacyPlists(candidate)
try journalStore.advance(to: .plistsRemoved)
try verifyEverythingAbsent()
try journalStore.finishWithoutLegacyPath()
return .notFound
```

Before each deletion phase, reopen the relevant root descriptor, compare device/inode with the candidate or journal, and generate a fresh manifest for only the remaining allowlisted targets. On error after journal creation, preserve the journal and return `.cleanupIncomplete(customerSafeMessage)`.

- [ ] **Step 5: Run cleaner, secure-tree, and policy tests**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/SecureFileTree.swift tests/swift/SecureFileTreeTests.swift \
  -o /tmp/mac-face-lock-secure-tree-tests &&
/tmp/mac-face-lock-secure-tree-tests
xcrun swiftc -parse-as-library -DTESTING \
  src/app/Models.swift src/app/ServiceManager.swift \
  src/app/SecureFileTree.swift src/app/LegacyInstallCleaner.swift \
  tests/swift/LegacyInstallCleanerTests.swift \
  -o /tmp/mac-face-lock-legacy-cleaner-tests &&
/tmp/mac-face-lock-legacy-cleaner-tests
python3 -m unittest tests.test_legacy_cleanup_policy -v
```

Expected: all three commands pass.

- [ ] **Step 6: Commit**

```bash
git add src/app/LegacyInstallCleaner.swift \
  tests/swift/LegacyInstallCleanerTests.swift
git commit -m "feat: clean source beta install one way"
```

---

### Task 4: Setup Coordinator Gate and Root Routing

**Files:**
- Modify: `src/app/SetupModels.swift`
- Modify: `src/app/SetupCoordinator.swift`
- Modify: `src/app/Views.swift`
- Modify: `src/app/AppDelegate.swift`
- Modify: `tests/swift/SetupStateTests.swift`
- Modify: `tests/swift/SetupCoordinatorTests.swift`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `LegacyInstallCleaning` from Task 2/3.
- Produces:

```swift
enum LegacyCleanupState: Equatable {
    case unchecked
    case notRequired
    case confirmationRequired
    case cleaning
    case ambiguous(String)
    case cleanupIncomplete(String)
    case completed
}

@Published private(set) var legacyCleanupState: LegacyCleanupState
var requiresLegacyCleanupAttention: Bool { get }
func inspectLegacyInstall() async
func confirmLegacyCleanup() async -> Bool
func retryLegacyCleanup() async -> Bool
func cancelLegacyCleanup()
```

- [ ] **Step 1: Write failing routing and coordinator tests**

Add root-routing tests:

```swift
try require(
    RootDestination.resolve(
        hasCompletedOnboarding: true,
        isLiveReady: true,
        requiresLegacyCleanupAttention: true
    ) == .onboarding,
    "legacy cleanup did not override a completed record"
)
```

Add a `FakeLegacyInstallCleaner` recording `inspect`, `clean`, and `retry`, and test:

- source mode starts `.notRequired` and never calls the cleaner;
- release mode starts `.unchecked`;
- inspection maps `.notFound`, `.confirmed`, `.ambiguous`, and `.cleanupIncomplete`;
- `prepareForSetup()` cannot advance while unchecked, confirmation-required, ambiguous, cleaning, or incomplete;
- cancel makes no cleaner call and cannot advance;
- confirm invokes `clean` only for the privately stored confirmed candidate;
- retry invokes only `retry`;
- completed cleanup still requires fresh enrollment;
- `refreshLiveReadiness`, `restartService`, `reinstallService`, diagnosis-time install, and completion polling make zero `ServiceManaging` calls before the gate clears.

Extend the existing `FakeServiceManager` with an exact status counter:

```swift
private(set) var statusChecks = 0

func status() async -> ServiceStatus {
    statusChecks += 1
    return currentStatus
}
```

```swift
private static func testServiceManagerIsUntouchedBeforeLegacyGateClears() async throws {
    let fixture = try CoordinatorFixture()
    defer { fixture.remove() }
    let cleaner = FakeLegacyInstallCleaner(
        inspection: .confirmed(fixture.legacyCandidate)
    )
    let service = FakeServiceManager(state: .healthy)
    let coordinator = SetupCoordinator(
        environment: fixture.environment,
        permissionCenter: PermissionCenter(provider: CoordinatorPermissionProvider()),
        setupStore: fixture.setupStore,
        localStore: fixture.localStore,
        serviceManager: service,
        legacyInstallCleaner: cleaner,
        ownerProfileInspector: FakeOwnerProfileInspector(valid: false)
    )

    await coordinator.inspectLegacyInstall()
    await coordinator.refreshLiveReadiness()
    await coordinator.restartService()
    await coordinator.reinstallService()

    try require(service.statusChecks == 0, "status read crossed cleanup gate")
    try require(service.restartCount == 0, "restart crossed cleanup gate")
    try require(service.installs.isEmpty, "install crossed cleanup gate")
}
```

- [ ] **Step 2: Run coordinator tests to verify they fail**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift src/app/AppEnvironment.swift \
  src/app/Models.swift src/app/SetupModels.swift \
  src/app/LocalJSONStore.swift src/app/SetupStore.swift \
  src/app/PermissionCenter.swift src/app/RuntimeCommandRunner.swift \
  src/app/ServiceManager.swift src/app/SecureFileTree.swift \
  src/app/LegacyInstallCleaner.swift src/app/SetupCoordinator.swift \
  tests/swift/SetupCoordinatorTests.swift \
  -framework AppKit -framework AVFoundation \
  -framework ApplicationServices -framework CoreGraphics \
  -o /tmp/mac-face-lock-setup-coordinator-tests
```

Expected: FAIL because cleanup state and coordinator APIs do not exist.

- [ ] **Step 3: Implement cleanup state and coordinator gates**

Use one gate for every service path:

```swift
private var legacyCleanupAllowsServiceAccess: Bool {
    environment.mode == .source
        || legacyCleanupState == .notRequired
        || legacyCleanupState == .completed
}

var requiresLegacyCleanupAttention: Bool {
    environment.mode == .release && !legacyCleanupAllowsServiceAccess
}

private func guardLegacyCleanupGate() -> Bool {
    guard legacyCleanupAllowsServiceAccess else {
        serviceHealthy = false
        serviceStatus = nil
        _ = try? localStore.writeControl(enabled: false)
        currentError = "请先完成旧版清理，再继续设置后台保护。"
        updateReadiness()
        return false
    }
    return true
}
```

Call `guardLegacyCleanupGate()` before every `ServiceManager.status`, `install`, `restart`, or uninstall-capable path. Keep the confirmed candidate private:

```swift
private var confirmedLegacyCandidate: LegacyCleanupCandidate?
```

Map inspection without exposing the path in UI state:

```swift
case .confirmed(let candidate):
    confirmedLegacyCandidate = candidate
    legacyCleanupState = .confirmationRequired
case .notFound:
    confirmedLegacyCandidate = nil
    legacyCleanupState = .notRequired
case .ambiguous(let message):
    confirmedLegacyCandidate = nil
    legacyCleanupState = .ambiguous(message)
case .cleanupIncomplete(let message):
    confirmedLegacyCandidate = nil
    legacyCleanupState = .cleanupIncomplete(message)
```

Implement the public actions with one result mapper:

```swift
func inspectLegacyInstall() async {
    guard environment.mode == .release,
          legacyCleanupState != .cleaning,
          let legacyInstallCleaner else {
        return
    }
    applyLegacyInspection(legacyInstallCleaner.inspect())
}

@discardableResult
func confirmLegacyCleanup() async -> Bool {
    guard case .confirmationRequired = legacyCleanupState,
          let candidate = confirmedLegacyCandidate,
          let legacyInstallCleaner else {
        currentError = "没有可确认的旧版清理任务。"
        return false
    }
    legacyCleanupState = .cleaning
    let result = await legacyInstallCleaner.clean(candidate)
    if result == .notFound {
        confirmedLegacyCandidate = nil
        legacyCleanupState = .completed
    } else {
        applyLegacyInspection(result)
    }
    return legacyCleanupState == .notRequired
        || legacyCleanupState == .completed
}

@discardableResult
func retryLegacyCleanup() async -> Bool {
    guard case .cleanupIncomplete = legacyCleanupState,
          let legacyInstallCleaner else {
        currentError = "没有可重试的旧版清理任务。"
        return false
    }
    legacyCleanupState = .cleaning
    let result = await legacyInstallCleaner.retry()
    if result == .notFound {
        confirmedLegacyCandidate = nil
        legacyCleanupState = .completed
    } else {
        applyLegacyInspection(result)
    }
    return legacyCleanupState == .notRequired
        || legacyCleanupState == .completed
}

func cancelLegacyCleanup() {
    guard case .confirmationRequired = legacyCleanupState else { return }
    currentError = "已取消旧版清理；完成清理前不会启用发行版保护。"
}
```

At the start of `prepareForSetup()`, inspect if the state is `.unchecked`, then require `legacyCleanupAllowsServiceAccess` before evaluating the existing preparation issues or persisting `.permissions`.

Source mode must set `legacyCleanupState = .notRequired` and `legacyInstallCleaner = nil`.

- [ ] **Step 4: Route the window and startup through the gate**

Change:

```swift
static func resolve(
    hasCompletedOnboarding: Bool,
    isLiveReady: Bool,
    requiresLegacyCleanupAttention: Bool
) -> RootDestination {
    if requiresLegacyCleanupAttention {
        return .onboarding
    }
    guard hasCompletedOnboarding else {
        return .onboarding
    }
    return isLiveReady ? .mainReady : .mainRecovery
}
```

In `AppDelegate`, start with:

```swift
Task {
    await setupCoordinator.inspectLegacyInstall()
    if setupCoordinator.requiresLegacyCleanupAttention {
        desktopWindowController.show()
    }
    await setupCoordinator.refreshLiveReadiness()
    faceLockStore.refresh()
    statusMenuController.refresh()
}
```

Pass `requiresLegacyCleanupAttention` from `Views.swift` into `RootDestination.resolve`.

- [ ] **Step 5: Update CI commands and run tests**

Add `src/app/SecureFileTree.swift src/app/LegacyInstallCleaner.swift` to the setup-coordinator CI compilation. Update the setup-state test calls with `requiresLegacyCleanupAttention: false` and add the true override test.

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/Models.swift src/app/SetupModels.swift \
  src/app/LocalJSONStore.swift src/app/SetupStore.swift \
  tests/swift/SetupStateTests.swift \
  -o /tmp/mac-face-lock-setup-state-tests &&
/tmp/mac-face-lock-setup-state-tests
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift src/app/AppEnvironment.swift \
  src/app/Models.swift src/app/SetupModels.swift \
  src/app/LocalJSONStore.swift src/app/SetupStore.swift \
  src/app/PermissionCenter.swift src/app/RuntimeCommandRunner.swift \
  src/app/ServiceManager.swift src/app/SecureFileTree.swift \
  src/app/LegacyInstallCleaner.swift src/app/SetupCoordinator.swift \
  tests/swift/SetupCoordinatorTests.swift \
  -framework AppKit -framework AVFoundation \
  -framework ApplicationServices -framework CoreGraphics \
  -o /tmp/mac-face-lock-setup-coordinator-tests &&
/tmp/mac-face-lock-setup-coordinator-tests
```

Expected: setup-state and setup-coordinator suites pass.

- [ ] **Step 6: Commit**

```bash
git add src/app/SetupModels.swift src/app/SetupCoordinator.swift \
  src/app/Views.swift src/app/AppDelegate.swift \
  tests/swift/SetupStateTests.swift tests/swift/SetupCoordinatorTests.swift \
  .github/workflows/ci.yml
git commit -m "feat: gate release setup on legacy cleanup"
```

---

### Task 5: Customer UI, Policy, and Documentation

**Files:**
- Modify: `src/app/OnboardingView.swift`
- Modify: `tests/test_legacy_cleanup_policy.py`
- Modify: `tests/test_packaging.py`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md`
- Modify: `docs/superpowers/specs/2026-07-18-defer-source-beta-migration-design.md`

**Interfaces:**
- Consumes: `SetupCoordinator.legacyCleanupState` and the four cleanup actions from Task 4.
- Produces: a non-technical destructive confirmation, cancel state, ambiguity block, progress state, and retry control.

- [ ] **Step 1: Write failing structural/customer-flow tests**

Replace the stale notice assertion with exact copy and actions:

```python
LEGACY_WARNING = (
    "检测到旧版 Mac Face Lock。继续将停止旧版后台服务，并永久删除旧版人脸模板、"
    "配置、活动记录、证据、日志和旧应用。源码、Git 历史、文档、脚本和 Python "
    "开发环境不会删除。此操作不可恢复。"
)

def test_release_onboarding_exposes_one_way_cleanup_flow(self) -> None:
    onboarding = (PROJECT_DIR / "src/app/OnboardingView.swift").read_text()
    for text in (
        LEGACY_WARNING,
        "清除旧版并继续",
        "取消",
        "重试清理",
        "检测到的旧版结构不完整",
    ):
        self.assertIn(text, onboarding)
    self.assertNotIn("原目录和数据将保持不变", onboarding)
    self.assertNotIn("导入旧版数据", onboarding)
```

Extend the packaging UI test to reject `launchctl`, shell commands, and raw legacy paths in `OnboardingView.swift`.

- [ ] **Step 2: Run Python tests to verify they fail**

Run:

```bash
python3 -m unittest \
  tests.test_legacy_cleanup_policy \
  tests.test_packaging -v
```

Expected: FAIL because the old “data remains” notice is still present and the new actions are absent.

- [ ] **Step 3: Implement state-specific preparation UI**

Replace the static notice with:

```swift
@ViewBuilder
private var legacyCleanupCard: some View {
    switch setupCoordinator.legacyCleanupState {
    case .unchecked:
        Label("正在检查旧版安装…", systemImage: "magnifyingglass")
    case .notRequired, .completed:
        Label("未发现需要清理的旧版运行环境", systemImage: "checkmark.circle.fill")
            .foregroundStyle(Color(nsColor: .systemGreen))
    case .confirmationRequired:
        legacyDestructiveConfirmation
    case .cleaning:
        Label("正在停止并清除旧版，请不要退出应用…", systemImage: "hourglass")
    case .ambiguous(let message):
        LegacyCleanupProblemCard(
            title: "检测到的旧版结构不完整",
            message: message,
            retryTitle: "重新检查",
            retry: { Task { await setupCoordinator.inspectLegacyInstall() } }
        )
    case .cleanupIncomplete(let message):
        LegacyCleanupProblemCard(
            title: "旧版清理尚未完成",
            message: message,
            retryTitle: "重试清理",
            retry: { Task { _ = await setupCoordinator.retryLegacyCleanup() } }
        )
    }
}
```

Define the referenced customer-safe problem card in the same file:

```swift
private struct LegacyCleanupProblemCard: View {
    let title: String
    let message: String
    let retryTitle: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(retryTitle, action: retry)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(
            Color(nsColor: .systemOrange).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}
```

The confirmation buttons must call only:

```swift
Button("清除旧版并继续", role: .destructive) {
    Task { _ = await setupCoordinator.confirmLegacyCleanup() }
}
Button("取消", role: .cancel) {
    setupCoordinator.cancelLegacyCleanup()
}
```

Disable “开始检查” unless cleanup state is `.notRequired` or `.completed`. In the preparation `.task`, call `inspectLegacyInstall()` once when state is `.unchecked`.

- [ ] **Step 4: Update public documentation**

README must state:

```text
如果发行版检测到本项目已知的源码测试版，会在首次设置中要求确认一次不可恢复的清理：
停止并移除旧 Agent 与旧状态服务，删除源码目录中的 config/config.json、data/、logs/
和已构建的 Mac Face Lock 应用。源码、Git 历史、文档、脚本与 .venv 保留。
旧人脸模板和设置不会导入；清理完成后必须重新授权、录入本人并完成安全测试。
卸载发行版不会恢复旧服务或旧数据。
```

In both older design documents, add a prominent “Superseded boundary” paragraph linking to `2026-07-18-one-way-legacy-cleanup-design.md`. Remove contradictory statements from the active self-contained design; retain historical context in the deferral design but label it superseded.

- [ ] **Step 5: Run UI, policy, and documentation checks**

Run:

```bash
python3 -m unittest \
  tests.test_legacy_cleanup_policy \
  tests.test_packaging -v
rg -n "原目录和数据将保持不变" \
  README.md src/app tests .github \
  docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md
```

Expected: Python tests pass; `rg` returns no matches in active product/customer documentation.

- [ ] **Step 6: Typecheck and commit**

Run:

```bash
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics
```

Expected: exit 0.

Commit:

```bash
git add src/app/OnboardingView.swift tests/test_legacy_cleanup_policy.py \
  tests/test_packaging.py README.md \
  docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md \
  docs/superpowers/specs/2026-07-18-defer-source-beta-migration-design.md
git commit -m "docs: explain one-way source beta cleanup"
```

---

### Task 6: Full Release-Gate Verification

**Files:**
- Modify only if a verification failure identifies a scoped defect in files already listed in Tasks 1–5.

**Interfaces:**
- Consumes: the complete implementation from Tasks 1–5.
- Produces: evidence that the source build, self-contained release build, tests, safety policies, signing, and minimum OS gates all pass together.

- [ ] **Step 1: Run the full Python suite**

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: all tests pass; record the exact test count in the execution report.

- [ ] **Step 2: Run all Swift executables**

Run the same commands as `.github/workflows/ci.yml`, including:

```bash
/tmp/mac-face-lock-secure-tree-tests
/tmp/mac-face-lock-legacy-cleaner-tests
/tmp/mac-face-lock-setup-state-tests
/tmp/mac-face-lock-setup-coordinator-tests
```

Expected: every executable prints its `... tests passed` message and exits 0.

- [ ] **Step 3: Typecheck and build both applications**

```bash
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics
scripts/build-app.sh
scripts/build-status-app.sh
```

Expected: both `dist/Mac Face Lock Agent.app` and `dist/Mac Face Lock.app` are rebuilt successfully.

- [ ] **Step 4: Validate plists, signatures, and minimum OS**

```bash
plutil -lint src/app/Info.plist \
  launchd/com.wuyi.mac-face-lock-agent.plist \
  launchd/com.wuyi.mac-face-lock-release.plist \
  launchd/com.wuyi.mac-face-lock-status.plist \
  "dist/Mac Face Lock Agent.app/Contents/Info.plist" \
  "dist/Mac Face Lock.app/Contents/Info.plist"
codesign --verify --deep --strict "dist/Mac Face Lock Agent.app"
codesign --verify --deep --strict "dist/Mac Face Lock.app"
for executable in \
  "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent" \
  "dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock"
do
  xcrun vtool -show-build "$executable" | awk '$1 == "minos" { exit($2 == "12.0" ? 0 : 1) }'
done
```

Expected: every plist is `OK`, both signatures verify, both executables report `minos 12.0`.

- [ ] **Step 5: Run destructive-scope audit**

```bash
python3 - <<'PY'
import re
from pathlib import Path
cleaner = Path("src/app/LegacyInstallCleaner.swift").read_text()
required = {
    "config/config.json",
    "data",
    "logs",
    "dist/Mac Face Lock Agent.app",
    "dist/Mac Face Lock.app",
    "dist/Mac Face Lock Status.app",
}
match = re.search(
    r"static let targets = \[(.*?)\n    \]",
    cleaner,
    flags=re.DOTALL,
)
assert match, "cleanup target declaration missing"
declared = set(re.findall(r'"([^"]+)"', match.group(1)))
assert declared == required, (declared, required)
print("legacy cleanup allowlist audit passed")
PY
```

Expected: `legacy cleanup allowlist audit passed`.

- [ ] **Step 6: Review the final diff**

```bash
git diff --check
git status --short
git log --oneline 6bc90f3..HEAD
```

Expected: no whitespace errors; only scoped changes/build artifacts are present; commits match Tasks 1–5.

- [ ] **Step 7: Commit only a scoped verification fix if needed**

If all gates pass without fixes, do not create an empty commit. If a gate found a defect, first add a regression test, make the smallest scoped fix, rerun the failed gate and the full affected suite, then commit:

```bash
git add src/app/SecureFileTree.swift src/app/LegacyInstallCleaner.swift \
  src/app/SetupModels.swift src/app/SetupCoordinator.swift \
  src/app/Views.swift src/app/OnboardingView.swift src/app/AppDelegate.swift \
  tests/swift/SecureFileTreeTests.swift \
  tests/swift/LegacyInstallCleanerTests.swift \
  tests/swift/SetupStateTests.swift tests/swift/SetupCoordinatorTests.swift \
  tests/test_legacy_cleanup_policy.py tests/test_packaging.py \
  .github/workflows/ci.yml README.md
git commit -m "fix: close legacy cleanup release gate"
```

Expected: the final worktree is clean after committing any required fix.

## Completion Boundary

This plan is complete only when every Task 6 gate passes from the current branch and an independent code review reports no P1 or P2 findings. Task 10/GitHub publication remains paused until that review and the existing release-readiness checks both pass.
