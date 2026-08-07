# Mac Face Lock Single-App Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Ship one Mac Face Lock.app whose main executable owns the UI, runtime commands, background protection, and one macOS permission identity.

**Architecture:** MacFaceLock becomes a strict mode dispatcher: ordinary launches run AppKit, while validated internal launches exec the bundled runtime for agent, enroll, diagnose, or verify-owner. The release LaunchAgent points back to the same main executable, and ServiceManager treats an already-correct responsive instance as an idempotent success while migrating the former Agent label safely.

**Tech Stack:** Swift/AppKit, Python 3.11/PyInstaller runtime, macOS launchd/TCC, standalone Swift tests, Python unittest, shell release tooling.

## Global Constraints

- The release archive contains one top-level Mac Face Lock.app and no embedded Mac Face Lock Agent.app.
- Camera, Input Monitoring, and Accessibility depend only on com.wuyi.mac-face-lock.app.
- The new LaunchAgent label is exactly com.wuyi.mac-face-lock-background and its program is Mac Face Lock.app/Contents/MacOS/MacFaceLock.
- Internal invocation is exactly --internal-runtime --resources-dir <path> --support-dir <path> <command>, with commands limited to agent, enroll, diagnose, and verify-owner.
- Unknown commands, relative paths, symlink escapes, bundle-external Resources, and support-directory mismatches fail before runtime execution.
- Closing the control-center window keeps the application resident; explicit quit first disables protection and stops the background task.
- Any camera, permission, owner, heartbeat, migration, or service error remains fail-open and writes or preserves protection_enabled=false.
- lock_on_camera_error remains false; camera errors never become stranger decisions.
- Owner templates, configuration, logs, activities, and evidence are preserved across migration, failure, and rollback.
- Existing application copies remain recoverable until live acceptance and explicit user-approved cleanup.
- Do not edit the macOS TCC database automatically.
- Do not push, merge, deploy, enable protection, or change privacy toggles without the required user authorization.

---

### Task 1: Add the single executable mode dispatcher

**Files:**
- Create: src/app/ApplicationLaunchMode.swift
- Modify: src/app/main.swift
- Create: tests/swift/ApplicationLaunchModeTests.swift
- Modify: .github/workflows/ci.yml

**Interfaces:**
- Consumes: Bundle.main.bundleURL, the user Application Support directory, and CommandLine.arguments.
- Produces: ApplicationLaunchMode.interface or ApplicationLaunchMode.runtime(RuntimeLaunchResolution); RuntimeLaunchResolution exposes executableURL: URL and execArguments: [String].

- [ ] **Step 1: Write dispatcher tests before production code**

Create a real temporary app fixture:

~~~swift
let bundle = root.appendingPathComponent("Mac Face Lock.app")
let resources = bundle.appendingPathComponent("Contents/Resources")
let runtime = resources.appendingPathComponent(
    "runtime/MacFaceLockRuntime/MacFaceLockRuntime"
)
let supportRoot = root.appendingPathComponent("Application Support")
let support = supportRoot.appendingPathComponent("Mac Face Lock")
~~~

Assert ordinary one-argument launch resolves to .interface. For each allowed command, assert the runtime is the executable inside Resources and arguments are exactly:

~~~swift
[
    runtime.path,
    "--resources-dir", resources.path,
    "--support-dir", support.path,
    command,
]
~~~

Also assert unknown/missing commands, relative paths, symlinked Resources, bundle-external Resources, and mismatched support paths throw. Test argv allocation appends nil and cleans earlier pointers when duplication fails.

- [ ] **Step 2: Run RED**

~~~bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ApplicationLaunchMode.swift \
  tests/swift/ApplicationLaunchModeTests.swift \
  -o /tmp/mac-face-lock-application-mode-tests
~~~

Expected: compilation fails because ApplicationLaunchMode.swift and its APIs do not exist.

- [ ] **Step 3: Implement the resolver**

Create these exact types and function:

~~~swift
enum ApplicationLaunchMode: Equatable {
    case interface
    case runtime(RuntimeLaunchResolution)
}

struct RuntimeLaunchResolution: Equatable {
    let executableURL: URL
    let execArguments: [String]
}

enum ApplicationLaunchModeError: Error, Equatable {
    case invalidInvocation
    case invalidResources(String)
    case invalidSupport(String)
    case missingRuntime(String)
    case argumentAllocationFailed
}

func resolveApplicationLaunch(
    arguments: [String],
    bundleURL: URL,
    applicationSupportURL: URL,
    fileManager: FileManager = .default
) throws -> ApplicationLaunchMode
~~~

Canonicalize all URLs, reject symlinks, require Resources to equal bundleURL/Contents/Resources, require support to equal applicationSupportURL/Mac Face Lock, and require the runtime executable at Resources/runtime/MacFaceLockRuntime/MacFaceLockRuntime.

- [ ] **Step 4: Dispatch before AppKit**

In main.swift, resolve before NSApplication.shared. Runtime mode allocates argv and calls execv; invalid invocation exits 64, unavailable runtime/exec exits 78, and errors write one concise stderr line. Interface mode retains the existing AppKit startup.

- [ ] **Step 5: Run GREEN and add CI**

Run the Step 2 command and expect Application launch mode tests passed. Add the same compile/run gate to CI and run git diff --check.

- [ ] **Step 6: Commit**

~~~bash
git add src/app/ApplicationLaunchMode.swift src/app/main.swift \
  tests/swift/ApplicationLaunchModeTests.swift .github/workflows/ci.yml
git commit -m "feat: add single app runtime dispatcher"
~~~

### Task 2: Route release commands through MacFaceLock

**Files:**
- Modify: src/app/AppEnvironment.swift
- Modify: src/app/RuntimeCommandRunner.swift
- Modify: tests/swift/AppEnvironmentTests.swift
- Modify: tests/swift/RuntimeCommandRunnerTests.swift

**Interfaces:**
- Consumes: the Task 1 internal invocation contract.
- Produces: release AppEnvironment.runtimeExecutableURL equal to bundle/Contents/MacOS/MacFaceLock; source mode remains .venv/bin/python.

- [ ] **Step 1: Add failing routing assertions**

In AppEnvironmentTests assert:

~~~swift
try require(
    environment.runtimeExecutableURL
        == bundleURL.appendingPathComponent("Contents/MacOS/MacFaceLock"),
    "release runtime did not use the single application identity"
)
~~~

In RuntimeCommandRunnerTests assert each release command receives:

~~~swift
[
    "--internal-runtime",
    "--resources-dir", environment.resourcesURL.path,
    "--support-dir", environment.supportURL.path,
    command.rawValue,
]
~~~

Also assert source mode still receives runtime_cli.py first and never receives --internal-runtime.

- [ ] **Step 2: Run RED**

~~~bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift src/app/AppEnvironment.swift \
  tests/swift/AppEnvironmentTests.swift \
  -o /tmp/mac-face-lock-environment-tests
/tmp/mac-face-lock-environment-tests

xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift src/app/AppEnvironment.swift \
  src/app/RuntimeCommandRunner.swift \
  tests/swift/RuntimeCommandRunnerTests.swift \
  -o /tmp/mac-face-lock-runtime-command-tests
/tmp/mac-face-lock-runtime-command-tests
~~~

Expected: release path/argv assertions fail.

- [ ] **Step 3: Implement release routing**

Set release runtimeExecutableURL to resolvedBundleURL/Contents/MacOS/MacFaceLock. Return the exact internal argv above for release mode. Preserve the existing source argv and JSON event validation.

- [ ] **Step 4: Run GREEN and commit**

~~~bash
git diff --check
git add src/app/AppEnvironment.swift src/app/RuntimeCommandRunner.swift \
  tests/swift/AppEnvironmentTests.swift tests/swift/RuntimeCommandRunnerTests.swift
git commit -m "fix: route release camera work through app identity"
~~~

### Task 3: Make background service single-identity and idempotent

**Files:**
- Modify: src/app/ServiceManager.swift
- Modify: tests/swift/ServiceManagerTests.swift
- Modify: launchd/com.wuyi.mac-face-lock-release.plist

**Interfaces:**
- Consumes: MacFaceLock --internal-runtime ... agent from Tasks 1-2.
- Produces: label com.wuyi.mac-face-lock-background, exact main executable path, idempotent healthy install, and recognized migration from the former release Agent plist.

- [ ] **Step 1: Add a failing idempotence regression**

Seed a loaded service with the new rendered plist, PID 42, fresh progressing heartbeat, and all permissions true. Call install and assert no bootout, bootstrap, or kickstart occurs; the service remains loaded with PID 42 and protection is written false.

- [ ] **Step 2: Add failing migration and unload tests**

Add exact tests proving:

- A recognized old com.wuyi.mac-face-lock-agent.plist is stopped and removed only after the new service becomes responsive.
- An unknown old plist under that name blocks before mutation.
- New bootstrap waits until launchctl print proves the old/current target absent after bootout.
- Failed new startup preserves old plist bytes for diagnosis and protection stays false.

- [ ] **Step 3: Run RED**

~~~bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/Models.swift src/app/ServiceManager.swift \
  tests/swift/ServiceManagerTests.swift \
  -o /tmp/mac-face-lock-service-manager-tests
/tmp/mac-face-lock-service-manager-tests
~~~

Expected: tests fail because the old label/path remain and every install mutates launchd.

- [ ] **Step 4: Implement identity and idempotence**

Use exact constants:

~~~swift
static let label = "com.wuyi.mac-face-lock-background"
static let legacyReleaseLabel = "com.wuyi.mac-face-lock-agent"
~~~

Expected program and args are:

~~~swift
[
    appURL.appendingPathComponent("Contents/MacOS/MacFaceLock").path,
    "--internal-runtime",
    "--resources-dir", appURL.appendingPathComponent("Contents/Resources").path,
    "--support-dir", supportURL.path,
    "agent",
]
~~~

At install start, write protection false, read status, and return when the matching installed service is responsive. Replacement/migration must poll bounded launchctl print until absent before bootstrap. Recognize the old release plist only when its full key set and arguments exactly match the previous embedded-Agent template for the same app/support URLs.

- [ ] **Step 5: Update template and run GREEN**

Set the template label to com.wuyi.mac-face-lock-background. ProgramArguments starts with __APP_URL__/Contents/MacOS/MacFaceLock and --internal-runtime, followed by existing Resources/support/agent values. Preserve working directory, logs, RunAtLoad, KeepAlive, and ProcessType=Background. Run Step 3 and expect Service manager tests passed.

- [ ] **Step 6: Commit**

~~~bash
git diff --check
git add src/app/ServiceManager.swift tests/swift/ServiceManagerTests.swift \
  launchd/com.wuyi.mac-face-lock-release.plist
git commit -m "fix: unify and stabilize background service identity"
~~~

### Task 4: Remove Agent from release packaging

**Files:**
- Modify: scripts/build-status-app.sh
- Modify: scripts/build-release.sh
- Modify: tests/test_packaging.py
- Modify: tests/test_release_bundle.py
- Modify: tests/test_open_source_policy.py
- Modify: .github/workflows/ci.yml

**Interfaces:**
- Consumes: the new plist and main dispatcher.
- Produces: a signed Mac Face Lock.app with runtime Resources and no LoginItems Agent app.

- [ ] **Step 1: Write final-shape assertions**

Replace positive embedded-Agent assertions with:

~~~python
self.assertFalse(
    (app / "Contents/Library/LoginItems/Mac Face Lock Agent.app").exists()
)
self.assertFalse(any(app.rglob("MacFaceLockAgent")))
self.assertNotIn(b"com.wuyi.mac-face-lock-agent.app", archive_bytes)
~~~

Assert release plist label/background program/internal flag exactly match Task 3.

- [ ] **Step 2: Run RED**

~~~bash
.venv/bin/python -m unittest \
  tests.test_packaging tests.test_release_bundle tests.test_open_source_policy -v
~~~

Expected: failures because build-status-app.sh still embeds and verifies Agent.app.

- [ ] **Step 3: Remove release embedding**

In build-status-app.sh remove Agent variables, fallback build-app.sh call, embedded copy, and embedded bundle validation. Require main executable, bundled runtime executable, Info.plist, and release plist. Preserve licenses, defaults, icon, generation recovery, Swift compilation, minos, and deep signing.

In build-release.sh remove embedded Agent signature checks and add explicit absence checks for the LoginItems Agent directory, MacFaceLockAgent, and old Agent Bundle ID.

- [ ] **Step 4: Update CI and run GREEN**

CI must no longer require building, linting, signing, or inspecting Agent.app as a release prerequisite. Verify the unified app and bundled runtime minos/signatures.

Run Step 2 and git diff --check.

- [ ] **Step 5: Commit**

~~~bash
git add scripts/build-status-app.sh scripts/build-release.sh \
  tests/test_packaging.py tests/test_release_bundle.py \
  tests/test_open_source_policy.py .github/workflows/ci.yml
git commit -m "build: ship one Mac Face Lock application"
~~~

### Task 5: Update UI, resident lifecycle, and explicit quit

**Files:**
- Create: src/app/ApplicationQuitCoordinator.swift
- Create: tests/swift/ApplicationQuitCoordinatorTests.swift
- Modify: src/app/AppDelegate.swift
- Modify: src/app/StatusMenuController.swift
- Modify: src/app/OnboardingView.swift
- Modify: src/app/SettingsView.swift
- Modify: src/app/SetupCoordinator.swift
- Modify: tests/swift/SetupCoordinatorTests.swift
- Modify: tests/test_packaging.py
- Modify: .github/workflows/ci.yml

**Interfaces:**
- Consumes: SetupCoordinator.uninstallServicePreservingData().
- Produces: ApplicationQuitCoordinator.requestQuit() async -> Bool; true permits termination, false keeps UI open with protection disabled.

- [ ] **Step 1: Add failing quit-order tests**

Create a fixture with recorded closures:

~~~swift
let subject = ApplicationQuitCoordinator(
    stopBackground: {
        calls.append("stop")
        return stopResult
    },
    terminate: { calls.append("terminate") }
)
~~~

Success must record stop then terminate. Failure records only stop. Concurrent requests coalesce to one stop. Cancellation never terminates before success.

- [ ] **Step 2: Add failing copy and safety assertions**

test_packaging.py requires absence of Agent 权限, 重新安装 Agent, and 退出界面; it requires Mac Face Lock 摄像头, Mac Face Lock 输入监控, Mac Face Lock 辅助功能, 修复后台保护, and 退出 Mac Face Lock 并停止保护.

SetupCoordinatorTests asserts quit-stop writes control false before service uninstall and never changes owner/onboarding records.

- [ ] **Step 3: Run RED**

~~~bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ApplicationQuitCoordinator.swift \
  tests/swift/ApplicationQuitCoordinatorTests.swift \
  -o /tmp/mac-face-lock-quit-tests

.venv/bin/python -m unittest tests.test_packaging -v
~~~

Expected: missing coordinator and old copy failures.

- [ ] **Step 4: Implement safe quit and residence**

Create:

~~~swift
@MainActor
final class ApplicationQuitCoordinator {
    init(
        stopBackground: @escaping () async -> Bool,
        terminate: @escaping () -> Void
    )
    func requestQuit() async -> Bool
}
~~~

Serialize requests, await stopBackground, terminate only on true, and return the result. Wire it in AppDelegate to SetupCoordinator.uninstallServicePreservingData and NSApp.terminate. Add applicationShouldTerminateAfterLastWindowClosed returning false.

Status menu displays 退出 Mac Face Lock 并停止保护, shows an NSAlert explaining protection stops, then requests quit. Failure shows the control center and keeps the process alive.

- [ ] **Step 5: Replace dual-identity copy**

Use exact titles:

~~~text
Mac Face Lock 摄像头
Mac Face Lock 输入监控
Mac Face Lock 辅助功能
~~~

Replace service actions with 修复后台保护 and remove user-facing Agent authorization/install wording.

- [ ] **Step 6: Run GREEN and commit**

Run quit tests, tests.test_packaging, and the existing SetupCoordinator suite, then:

~~~bash
git diff --check
git add src/app/ApplicationQuitCoordinator.swift \
  tests/swift/ApplicationQuitCoordinatorTests.swift \
  src/app/AppDelegate.swift src/app/StatusMenuController.swift \
  src/app/OnboardingView.swift src/app/SettingsView.swift \
  src/app/SetupCoordinator.swift tests/swift/SetupCoordinatorTests.swift \
  tests/test_packaging.py .github/workflows/ci.yml
git commit -m "feat: make Mac Face Lock a resident single app"
~~~

### Task 6: Full automated acceptance and release build

**Files:**
- Verify: all tracked files
- Generate ignored: dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip
- Generate ignored: dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip.sha256

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: one checksum-verified, deep-signed single-app release archive.

- [ ] **Step 1: Run Python once and serially**

~~~bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
~~~

Expected: all tests pass; only documented release-artifact skips are allowed.

- [ ] **Step 2: Compile affected Swift suites freshly**

Run the CI commands for ApplicationLaunchModeTests, AppEnvironmentTests, RuntimeCommandRunnerTests, ServiceManagerTests, ApplicationQuitCoordinatorTests, SetupCoordinatorTests, and LegacyInstallCleanerTests. Every binary must exit 0 with its pass banner.

- [ ] **Step 3: Typecheck complete app**

~~~bash
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift \
  -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics
~~~

Expected: no compiler error.

- [ ] **Step 4: Build and verify release**

~~~bash
scripts/build-release.sh
checksum_file="dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip.sha256"
(
  cd "$(dirname "$checksum_file")" || exit 1
  shasum -a 256 -c "$(basename "$checksum_file")"
)
scripts/manual-release-acceptance.sh
~~~

Expected: extracted bundle tests pass, one app/no Agent app, checksum OK, deep signature valid, automatic preflight PASS.

- [ ] **Step 5: Record artifact and Git evidence**

~~~bash
wc -c dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip
shasum -a 256 dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip
git diff --check
git status --short --branch
~~~

Generated release files remain ignored and uncommitted.

### Task 7: Install and complete live acceptance

**Files and system state:**
- Replace recoverably: /Applications/Mac Face Lock.app
- Preserve: /Applications/Mac Face Lock.next.app
- Preserve: /Applications/Mac Face Lock.pre-bootstrap.app
- Preserve: ~/Library/Application Support/Mac Face Lock/**
- Migrate: com.wuyi.mac-face-lock-agent to com.wuyi.mac-face-lock-background

**Interfaces:**
- Consumes: verified Task 6 archive and existing owner profile.
- Produces: a live accepted single-identity product with explicit protection disposition.

- [ ] **Step 1: Capture pre-install evidence**

Record owner-template SHA-256, onboarding/control/state, jobs, installed hashes, archive size/SHA, and protection false. Stop if owner template is missing or protection true.

- [ ] **Step 2: Recoverable atomic install**

Quit through the normal safe path. Extract the verified ZIP to a fresh temporary directory, stage beside the installed app, atomically swap, and retain every prior app copy under an unused explicit sibling. Verify deep strict code signing before launch.

- [ ] **Step 3: Prove one identity**

~~~bash
test ! -e "/Applications/Mac Face Lock.app/Contents/Library/LoginItems/Mac Face Lock Agent.app"
! find "/Applications/Mac Face Lock.app" -name MacFaceLockAgent -print -quit | grep -q .
launchctl print "gui/$(id -u)/com.wuyi.mac-face-lock-background"
~~~

Program must be installed Contents/MacOS/MacFaceLock, old Agent job absent, PID stable, heartbeats fresh/advancing, protection false.

- [ ] **Step 4: Pause for privacy action**

Open Camera, Input Monitoring, and Accessibility from the app. Do not toggle autonomously. Ask user to enable Mac Face Lock in all three. If the historical Agent row remains, cleanup requires separate user confirmation.

- [ ] **Step 5: Complete safety test**

With user facing camera, run once. All four checks green, three permissions enabled, onboarding advances, owner hash unchanged, protection still false.

- [ ] **Step 6: Verify close, reopen, quit, relaunch**

Close window: menu and background continue. Reopen window: state consistent. After user confirms impact, explicit quit stops job and leaves protection false. Relaunch restores background idempotently without enabling protection.

- [ ] **Step 7: Pause before active protection**

Ask immediately before 开启保护. After confirmation verify protection true, permissions/owner validation still pass, PID/heartbeat fresh, and camera/permission errors do not lock owner.

- [ ] **Step 8: Record closeout without pushing**

Report commit, artifact size/SHA, automated results, installed hash, launchd label/program/PID/heartbeats, permission rows, owner hash, lifecycle behavior, and protection disposition. Keep backups until user explicitly accepts cleanup; do not push.
