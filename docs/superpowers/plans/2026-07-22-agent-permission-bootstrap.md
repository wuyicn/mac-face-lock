# Mac Face Lock Agent Permission Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a responsive release Agent installed while macOS permissions are pending, without weakening the permission gate for safety testing or protection enablement.

**Architecture:** `ServiceStatus` will expose two independent facts: `isResponsive` for process/PID/fresh-progressing-heartbeat health and `isHealthy` for full protection readiness. `ServiceManager.install` will stabilize against `isResponsive`; `SetupCoordinator` will continue using the stricter `isHealthy`, so missing permissions remain a hard block while the Agent stays alive long enough to be authorized.

**Tech Stack:** Swift 6 command-line tests, Swift/AppKit release application, Python 3.11 `unittest`, macOS LaunchAgent/TCC APIs, PyInstaller release runtime, ad-hoc code signing.

## Global Constraints

- Protection remains disabled until camera, input monitoring, accessibility, owner profile, diagnosis, owner verification, and service health all pass.
- Missing TCC permissions must not roll back an otherwise responsive Agent installation.
- Missing or stale heartbeat, PID mismatch, stopped state, input-listener failure, invalid plist, or `launchctl` failure must still roll back.
- Camera and permission failures remain fail-open and must never be treated as a stranger result.
- Do not change face matching, enrollment, locking thresholds, signing/notarization scope, or notification routing.
- Preserve `~/Library/Application Support/Mac Face Lock` and the unrelated deletion in the main worktree at `config/config.json`.
- Do not push GitHub or merge branches without separate user authorization.

---

### Task 1: Separate Agent responsiveness from protection readiness

**Files:**
- Modify: `tests/swift/ServiceManagerTests.swift:241-260,290-310,662-679`
- Modify: `src/app/ServiceManager.swift:11-47,352-438,538-580`

**Interfaces:**
- Consumes: `FaceLockState.agentPid`, `status`, `heartbeatTimestamp`, `heartbeatSequence`, and the three Agent permission booleans.
- Produces: `ServiceStatus.isResponsive: Bool`; `ServiceStatus.isHealthy` retains its existing strict meaning.

- [ ] **Step 1: Extend the state-sequence fixture and write the failing regression test**

Change `seedHealthyStateSequence` so tests can model a responsive Agent with pending permissions:

```swift
func seedHealthyStateSequence(
    pid: Int32 = 42,
    sequences: [UInt64],
    timestamp: String = "2026-07-17T00:00:09Z",
    camera: Bool = true,
    inputMonitoring: Bool = true,
    accessibility: Bool = true
) throws {
    let data = try sequences.map { sequence in
        try JSONSerialization.data(
            withJSONObject: [
                "status": "paused",
                "armed": false,
                "agent_pid": Int(pid),
                "camera_ready": camera,
                "input_monitoring_ready": inputMonitoring,
                "accessibility_ready": accessibility,
                "heartbeat_sequence": sequence,
                "heartbeat_timestamp": timestamp,
            ] as [String: Any]
        )
    }
    fileSystem.seedReadSequence(data, at: stateURL)
}
```

Register and add this test:

```swift
try await testStableInstallAllowsPendingPermissions()

private static func testStableInstallAllowsPendingPermissions() async throws {
    let fixture = try ServiceFixture(printPIDs: [42, 42, 42, 42])
    try fixture.seedHealthyStateSequence(
        sequences: [1, 2, 3],
        inputMonitoring: false,
        accessibility: false
    )

    try await fixture.manager().install(
        appURL: fixture.appURL,
        supportURL: fixture.supportURL
    )

    let status = await fixture.manager().status()
    try require(
        fixture.fileSystem.fileExists(at: fixture.plistURL),
        "pending permissions rolled back a responsive Agent installation"
    )
    try require(status.isResponsive, "responsive Agent was not reported responsive")
    try require(!status.isHealthy, "pending Agent permissions reported protection ready")
    try require(status.cameraReady, "camera grant was lost")
    try require(!status.inputMonitoringReady, "input-monitoring denial was ignored")
    try require(!status.accessibilityReady, "accessibility denial was ignored")
    try require(fixture.runner.bootstrapCount == 1, "responsive install unexpectedly rolled back")
}
```

- [ ] **Step 2: Run the focused test binary and verify RED**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/Models.swift src/app/ServiceManager.swift \
  tests/swift/ServiceManagerTests.swift \
  -o /tmp/mac-face-lock-service-manager-tests
/tmp/mac-face-lock-service-manager-tests
```

Expected: FAIL from `ServiceManagerError.unstableService`; the current installer rejects the permission-pending state before the new assertions can pass.

- [ ] **Step 3: Implement the minimal two-layer status model**

Add a defaulted responsiveness field so existing test fixtures remain source-compatible:

```swift
struct ServiceStatus: Equatable {
    let state: ServiceState
    let pid: Int32?
    let cameraReady: Bool
    let inputMonitoringReady: Bool
    let accessibilityReady: Bool
    let installedProgram: String?
    let expectedProgram: String
    let heartbeatTimestamp: String?
    let heartbeatSequence: UInt64?
    let isResponsive: Bool

    init(
        state: ServiceState,
        pid: Int32?,
        cameraReady: Bool,
        inputMonitoringReady: Bool,
        accessibilityReady: Bool,
        installedProgram: String?,
        expectedProgram: String,
        heartbeatTimestamp: String? = nil,
        heartbeatSequence: UInt64? = nil,
        isResponsive: Bool = false
    ) {
        self.state = state
        self.pid = pid
        self.cameraReady = cameraReady
        self.inputMonitoringReady = inputMonitoringReady
        self.accessibilityReady = accessibilityReady
        self.installedProgram = installedProgram
        self.expectedProgram = expectedProgram
        self.heartbeatTimestamp = heartbeatTimestamp
        self.heartbeatSequence = heartbeatSequence
        self.isResponsive = isResponsive
    }

    var isHealthy: Bool {
        state == .healthy
    }
}
```

In `status(commandTimeout:)`, calculate process health independently from permission health:

```swift
let responsive = state?.agentPid == pid
    && heartbeatSequence != nil
    && heartbeatFresh
    && runningState
let healthy = responsive
    && cameraReady
    && inputMonitoringReady
    && accessibilityReady
return ServiceStatus(
    state: healthy ? .healthy : .unhealthy,
    pid: pid,
    cameraReady: cameraReady,
    inputMonitoringReady: inputMonitoringReady,
    accessibilityReady: accessibilityReady,
    installedProgram: installedProgram,
    expectedProgram: expectedProgram,
    heartbeatTimestamp: heartbeatTimestamp,
    heartbeatSequence: heartbeatSequence,
    isResponsive: responsive
)
```

Rename `requireStableHealth()` to `requireStableResponsiveness()`, update its install call, replace `current.isHealthy` with `current.isResponsive`, and rename its local counter to `consecutiveResponsivePolls`. Keep the three-progressing-heartbeat requirement, total timeout, PID reset behavior, and `unstableService` error unchanged.

- [ ] **Step 4: Run the focused suite and verify GREEN**

Run the same compile-and-test command from Step 2.

Expected: `Service manager tests passed`. The new test proves pending permissions preserve the service; existing tests prove full readiness, rollback, heartbeat progression, and timeout behavior remain strict.

- [ ] **Step 5: Confirm coordinator readiness remains strict**

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
/tmp/mac-face-lock-setup-coordinator-tests
```

Expected: `Setup coordinator tests passed`, including the existing rule that visible-app grants cannot override unhealthy Agent permissions.

- [ ] **Step 6: Review and commit the behavioral fix**

Run:

```bash
git diff --check
git diff -- src/app/ServiceManager.swift tests/swift/ServiceManagerTests.swift
git add src/app/ServiceManager.swift tests/swift/ServiceManagerTests.swift
git commit -m "fix: keep responsive agent while permissions are pending"
```

Expected: only the two listed files are committed; the commit succeeds.

### Task 2: Run complete automated acceptance and build the release

**Files:**
- Verify: all tracked source and test files
- Generate (ignored): `dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip`
- Generate (ignored): `dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip.sha256`

**Interfaces:**
- Consumes: the Task 1 commit and existing release scripts.
- Produces: a checksum-verified arm64 beta archive whose extracted app passes bundle tests and strict code-sign verification.

- [ ] **Step 1: Run Python and the two affected Swift suites**

Run:

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
/tmp/mac-face-lock-service-manager-tests
/tmp/mac-face-lock-setup-coordinator-tests
```

Expected: all tests pass; documented release-only skips are allowed, but failures and errors are not.

- [ ] **Step 2: Typecheck the complete Swift application**

Run:

```bash
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift \
  -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics
```

Expected: exit code 0 with no compiler error.

- [ ] **Step 3: Build and verify the complete release archive**

Run:

```bash
scripts/build-release.sh
checksum_file="dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip.sha256"
(
  cd "$(dirname "$checksum_file")" || exit 1
  shasum -a 256 -c "$(basename "$checksum_file")"
)
scripts/manual-release-acceptance.sh
```

Expected: runtime and app builds succeed, extracted release-bundle tests pass, checksum reports `OK`, strict code-sign verification passes, and automatic preflight reports `PASS` before printing the manual checklist.

- [ ] **Step 4: Verify the implementation worktree is clean**

Run:

```bash
git status --short --branch
git merge-base --is-ancestor 4920224 HEAD
git merge-base --is-ancestor 466c73e HEAD
git merge-base --is-ancestor 999de4b HEAD
git log --oneline -5
```

Expected: the worktree is clean; all three ancestry checks exit 0, proving `4920224`, `466c73e`, and `999de4b` are reachable from the current `HEAD`; and the short log provides review context. Subsequent commits are allowed only when they are plan-only corrections; do not predict a new commit SHA. Generated `dist/` output remains ignored.

### Task 2A: Install the release Agent even when diagnosis is permission-blocked

**Files:**
- Modify: `src/app/SetupCoordinator.swift`
- Modify: `tests/swift/SetupCoordinatorTests.swift`

**Interfaces:**
- Consumes: a release-mode safety test whose foreground diagnosis may fail because Agent permissions are not yet registered.
- Produces: an attempted responsive Agent installation regardless of diagnosis result, while diagnosis, service health, owner verification, and protection gates remain strict.

- [ ] **Step 1: Add a failing coordinator regression test**

Add a release-mode test whose diagnostic result exits `10` with a camera/permission failure. Run `runSafetyTest()` and assert that it returns `false`, leaves protection disabled, and still calls `ServiceManaging.install(...)` exactly once with the release app and support paths.

- [ ] **Step 2: Prove RED**

Compile and run the Setup coordinator Swift suite with the Task 1 command. Expected: the new assertion fails because `installAndRefreshReleaseService` currently returns when `diagnosisPassed` is false.

- [ ] **Step 3: Decouple bootstrap from the diagnosis gate**

In `installAndRefreshReleaseService`, require only a valid cleanup generation and an available release `serviceManager` before installing. Do not relax `runSafetyTest`'s `guard diagnosisPassed`, `ServiceStatus.isHealthy`, readiness checks, or `enableProtection` gates.

- [ ] **Step 4: Prove GREEN and commit**

Run the Setup coordinator Swift suite, the Service manager Swift suite, and `git diff --check`. Expected: both suites pass, the regression proves permission-blocked diagnosis still bootstraps the Agent, and no protection gate changes. Commit only the two implementation/test files with `fix: bootstrap agent before permission diagnosis passes`.

### Task 3: Install safely and close the real macOS permission loop

**Files and system state:**
- Replace: `/Applications/Mac Face Lock.app`
- Preserve: `~/Library/Application Support/Mac Face Lock/**`
- Create temporarily: a sibling staged app under `/Applications` for atomic swap
- Manage: `~/Library/LaunchAgents/com.wuyi.mac-face-lock-agent.plist`

**Interfaces:**
- Consumes: the verified archive from Task 2 and the existing enrolled owner profile.
- Produces: a running permission-pending Agent that remains installed, followed by strict permission-complete safety-test evidence.

- [ ] **Step 1: Capture preservation and safety evidence before installation**

Record without modifying support data:

```bash
face_lock_support_dir="$HOME/Library/Application Support/Mac Face Lock"
shasum -a 256 \
  "$face_lock_support_dir/data/owner_face.npy"
plutil -p \
  "$face_lock_support_dir/data/onboarding.json"
plutil -p \
  "$face_lock_support_dir/data/control.json"
```

Expected: the owner template exists, onboarding remains at `safety_test`, and `protection_enabled` is `false`.

- [ ] **Step 2: Replace only the installed app using a recoverable atomic swap**

Quit only `Mac Face Lock` through its normal application menu. Confirm that no previous staging path exists, extract the verified ZIP into a fresh temporary directory, stage the extracted app beside the installed app, and atomically swap them:

```bash
test ! -e "/Applications/Mac Face Lock.next.app"
acceptance_extract_dir=$(mktemp -d)
ditto -x -k \
  "dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip" \
  "$acceptance_extract_dir"
ditto \
  "$acceptance_extract_dir/Mac Face Lock.app" \
  "/Applications/Mac Face Lock.next.app"
python3 scripts/atomic-swap.py \
  "/Applications/Mac Face Lock.next.app" \
  "/Applications/Mac Face Lock.app"
codesign --verify --deep --strict "/Applications/Mac Face Lock.app"
```

Expected: the new app is installed and verified; the swapped previous app remains recoverable at `/Applications/Mac Face Lock.next.app` until acceptance completes. Do not delete either support data or the recoverable previous app during this task.

- [ ] **Step 3: Reproduce the pending-permission path once**

Open the installed app and click `运行安全测试` once while protection remains disabled. Then inspect:

```bash
face_lock_support_dir="$HOME/Library/Application Support/Mac Face Lock"
launchctl print "gui/$(id -u)/com.wuyi.mac-face-lock-agent"
plutil -p "$face_lock_support_dir/data/state.json"
plutil -p "$face_lock_support_dir/data/control.json"
```

Expected within a few advancing heartbeats: the LaunchAgent remains loaded with a stable nonzero PID; `camera_ready`, `input_monitoring_ready`, and `accessibility_ready` show their actual values; at least one pending permission keeps the safety test incomplete; `protection_enabled` remains `false`. Waiting five minutes must no longer remove the plist or stop the Agent.

- [ ] **Step 4: Verify Agent rows, then pause for the user's macOS permission action**

Use the app's three `打开系统设置` buttons and read the Camera, Input Monitoring, and Accessibility lists. Expected: `Mac Face Lock Agent` is present as the distinct background identity.

Do not toggle privacy permissions autonomously. Ask the user to enable the `Mac Face Lock Agent` rows that are still off, then return to the app.

- [ ] **Step 5: Run final safety-test acceptance**

Click `运行安全测试` with the user facing the camera. Verify all four checks become green, all three Agent permissions show `已开启`, and onboarding advances to `完成并开启`.

Re-run the pre-install evidence commands. Expected: owner template SHA-256 is unchanged, onboarding advances without losing the owner fingerprint, and protection is still disabled until the explicit final enable action.

- [ ] **Step 6: Pause before enabling active protection**

Because active protection can lock the Mac after input activity, ask the user for confirmation immediately before clicking `开启保护`. After confirmation, enable it and verify:

```bash
face_lock_support_dir="$HOME/Library/Application Support/Mac Face Lock"
plutil -p "$face_lock_support_dir/data/control.json"
launchctl print "gui/$(id -u)/com.wuyi.mac-face-lock-agent"
```

Expected: `protection_enabled` is `true`, the Agent keeps a stable PID with fresh advancing heartbeat, and no camera/permission error locks the owner.

- [ ] **Step 7: Record closeout evidence without pushing**

Collect:

```bash
git rev-parse HEAD
wc -c dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip
shasum -a 256 dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip
git status --short --branch
```

Report the exact commit, archive size/SHA-256, automated test results, LaunchAgent/PID/heartbeat state, three permission states, owner-template preservation, and whether protection was explicitly enabled. Keep the previous swapped app recoverable until the user accepts final removal; do not push GitHub.
