# Mac Face Lock Self-Contained Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver an Apple Silicon open-source Beta that a customer can download and configure without Codex, Python, Xcode Command Line Tools, or Terminal.

**Architecture:** Keep the tested Python/OpenCV protection core, add explicit runtime paths and a structured command-line boundary, freeze it into an arm64 self-contained runtime with PyInstaller 6.21.0, and embed that runtime plus the hidden Agent inside the SwiftUI application. The visible application owns onboarding, permission status, service installation, service diagnostics, and settings; protection remains disabled until every required gate passes.

**Tech Stack:** Swift 5 / SwiftUI / AppKit / AVFoundation / ApplicationServices / CoreGraphics, Python 3.11, PyInstaller 6.21.0, OpenCV 4.10.0.84, NumPy 1.26.4, unittest, LaunchAgent, ad-hoc codesigning.

## Global Constraints

- Target Apple Silicon and macOS 12.0 or newer.
- Release mode must not require Codex, system Python, Xcode, Terminal, a source checkout, or `.venv`.
- The downloaded application must finish onboarding while offline.
- Protection defaults to disabled until required permissions, owner enrollment, runtime diagnosis, service health, and an owner verification test pass.
- Camera failures remain fail-open and must never be treated as a stranger result.
- Test mode must never dispatch a real lock.
- Face templates, settings, records, logs, and evidence remain local.
- Release data lives under `~/Library/Application Support/Mac Face Lock/`.
- Source mode and current contributor workflows remain supported.
- The release remains ad-hoc signed and explicitly not notarized.

---

## File Structure

New focused units:

- `runtime_paths.py`: Python resource, support, data, config, and log path contract.
- `runtime_cli.py`: structured `agent`, `enroll`, `diagnose`, and `verify-owner` entry point.
- `template_store.py`: validation and atomic owner-template replacement.
- `src/app/AppEnvironment.swift`: source/release environment resolution.
- `src/app/SetupModels.swift`: onboarding state, permission state, and readiness gates.
- `src/app/SetupStore.swift`: persistent onboarding state.
- `src/app/PermissionCenter.swift`: macOS permission probes, requests, and settings links.
- `src/app/RuntimeCommandRunner.swift`: JSON-lines process runner for the frozen runtime.
- `src/app/ServiceManager.swift`: user LaunchAgent install, verification, restart, and rollback.
- `src/app/SetupCoordinator.swift`: orchestration across permissions, runtime, template, and service.
- `src/app/OnboardingView.swift`: five-step first-run experience.
- `src/app/SettingsView.swift`: operational settings sections.
- `scripts/build-runtime.sh`: reproducible PyInstaller build.
- `scripts/build-release.sh`: complete app, manifest, zip, and checksum build.
- `packaging/mac-face-lock-runtime.spec`: PyInstaller collection rules.

Existing files retain their current responsibilities. `Views.swift` loses only the settings implementation and adds onboarding routing; the protection and activity views are not redesigned.

---

### Task 1: Introduce Explicit Python Runtime Paths

**Files:**
- Create: `runtime_paths.py`
- Create: `tests/test_runtime_paths.py`
- Modify: `activity_store.py`
- Modify: `control_store.py`
- Modify: `evidence_store.py`
- Modify: `state_store.py`
- Modify: `face_verifier.py`
- Modify: `agent.py`

**Interfaces:**
- Produces: `RuntimePaths.for_source(root: Path) -> RuntimePaths`
- Produces: `RuntimePaths.for_release(resources_dir: Path, support_dir: Path) -> RuntimePaths`
- Produces immutable fields `resources_dir`, `support_dir`, `config_path`, `data_dir`, `logs_dir`, `owner_face_path`, `state_path`, `control_path`, `activity_path`, and `evidence_dir`.
- Existing store functions accept optional explicit `Path` arguments while preserving source-mode defaults.

- [ ] **Step 1: Write the failing runtime-path tests**

```python
class RuntimePathsTests(unittest.TestCase):
    def test_release_paths_keep_resources_read_only_and_state_in_support(self):
        paths = RuntimePaths.for_release(Path("/Applications/App/Resources"), Path("/tmp/support"))
        self.assertEqual(paths.config_path, Path("/tmp/support/config/config.json"))
        self.assertEqual(paths.owner_face_path, Path("/tmp/support/data/owner_face.npy"))
        self.assertEqual(paths.logs_dir, Path("/tmp/support/logs"))

    def test_source_paths_preserve_existing_layout(self):
        paths = RuntimePaths.for_source(Path("/tmp/source"))
        self.assertEqual(paths.config_path, Path("/tmp/source/config/config.json"))
        self.assertEqual(paths.owner_face_path, Path("/tmp/source/data/owner_face.npy"))
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `python -m unittest tests.test_runtime_paths -v`  
Expected: `ModuleNotFoundError: No module named 'runtime_paths'`.

- [ ] **Step 3: Implement the immutable path contract**

```python
@dataclass(frozen=True)
class RuntimePaths:
    resources_dir: Path
    support_dir: Path
    config_path: Path
    data_dir: Path
    logs_dir: Path

    @classmethod
    def for_release(cls, resources_dir: Path, support_dir: Path) -> "RuntimePaths":
        return cls(
            resources_dir=resources_dir.resolve(),
            support_dir=support_dir.resolve(),
            config_path=support_dir / "config" / "config.json",
            data_dir=support_dir / "data",
            logs_dir=support_dir / "logs",
        )
```

Add computed path properties and `ensure_writable_directories()`. Refactor module globals into optional arguments, for example `read_control(path: Path = CONTROL_PATH)` and `write_state(payload, path: Path = STATE_PATH)`. Construct one `RuntimePaths` in `agent.py` and pass its paths into stores, verifier, evidence, PID, and log setup.

- [ ] **Step 4: Run focused and regression tests**

Run: `python -m unittest tests.test_runtime_paths tests.test_control_store tests.test_activity_store tests.test_agent_control -v`  
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add runtime_paths.py activity_store.py control_store.py evidence_store.py state_store.py face_verifier.py agent.py tests/test_runtime_paths.py
git commit -m "refactor: make runtime data paths explicit"
```

---

### Task 2: Add Structured Runtime Commands and Safe Template Replacement

**Files:**
- Create: `runtime_cli.py`
- Create: `template_store.py`
- Create: `tests/test_runtime_cli.py`
- Create: `tests/test_template_store.py`
- Modify: `face_verifier.py`
- Modify: `enroll_owner.py`
- Modify: `camera_diagnostic.py`
- Modify: `agent.py`

**Interfaces:**
- Produces CLI: `runtime_cli.py --resources-dir PATH --support-dir PATH <agent|enroll|diagnose|verify-owner>`.
- Produces one JSON object per stdout line with `schema_version`, `event`, `status`, `message`, and command-specific fields.
- Produces exit codes: `0` success, `2` invalid arguments, `10` permission/camera unavailable, `11` owner profile invalid, `12` owner verification failed, `20` runtime/internal failure.
- Produces: `replace_owner_template(candidate: np.ndarray, destination: Path) -> None`.

- [ ] **Step 1: Write failing template and CLI tests**

```python
def test_atomic_template_replacement_keeps_old_profile_on_invalid_candidate(self):
    destination = self.root / "owner_face.npy"
    np.save(destination, np.ones((2, 96 * 96), dtype="float32"))
    with self.assertRaises(ValueError):
        replace_owner_template(np.array([np.nan], dtype="float32"), destination)
    self.assertTrue(np.isfinite(np.load(destination)).all())

def test_diagnose_emits_versioned_json(self):
    result = run_cli("diagnose", probe=PassingProbe())
    event = json.loads(result.stdout.splitlines()[-1])
    self.assertEqual(event["schema_version"], 1)
    self.assertEqual(event["event"], "diagnosis_complete")
```

- [ ] **Step 2: Run and verify RED**

Run: `python -m unittest tests.test_template_store tests.test_runtime_cli -v`  
Expected: imports fail because the new modules do not exist.

- [ ] **Step 3: Implement JSON event output and template transaction**

Validate candidate templates as finite `float32`, two-dimensional, at least two samples, and exactly `96 * 96` columns. Write to a sibling temporary `.npy`, reopen and validate it, `os.replace()` it into place, and remove the temporary file in `finally`.

Implement:

```python
def emit(event: str, status: str, message: str, **fields: object) -> None:
    payload = {
        "schema_version": 1,
        "event": event,
        "status": status,
        "message": message,
        **fields,
    }
    print(json.dumps(payload, ensure_ascii=False), flush=True)
```

Make enrollment emit `enrollment_started`, repeated `enrollment_progress`, and `enrollment_complete`. Make diagnosis report runtime imports, support-directory writes, camera access, and template validity independently. Make `verify-owner` run the existing verifier without invoking the lock controller.

- [ ] **Step 4: Prove test mode cannot lock**

Add a test that patches `lock_controller.lock_screen` to raise if called, invokes `verify-owner`, and asserts success without the patch being called.

Run: `python -m unittest tests.test_runtime_cli tests.test_template_store tests.test_agent_control -v`  
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add runtime_cli.py template_store.py face_verifier.py enroll_owner.py camera_diagnostic.py agent.py tests/test_runtime_cli.py tests/test_template_store.py
git commit -m "feat: add structured offline runtime commands"
```

---

### Task 3: Resolve Source and Release App Environments

**Files:**
- Create: `src/app/AppEnvironment.swift`
- Create: `tests/swift/AppEnvironmentTests.swift`
- Modify: `src/app/ProjectLocator.swift`
- Modify: `src/app/AppDelegate.swift`
- Modify: `src/app/LocalJSONStore.swift`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `AppEnvironment.resolve(arguments:bundleURL:applicationSupportURL:fileManager:) throws -> AppEnvironment`.
- `--source-root ABSOLUTE_PATH` selects source mode; one legacy absolute-path argument remains accepted so existing installed source LaunchAgents continue to start.
- No mode argument selects release mode using bundle resources and `Application Support/Mac Face Lock`.
- Produces `mode`, `resourcesURL`, `supportURL`, `configURL`, `dataURL`, `logsURL`, and `runtimeExecutableURL`.

- [ ] **Step 1: Write failing Swift environment tests**

Cover:

```swift
let release = try AppEnvironment.resolve(
    arguments: ["MacFaceLock"],
    bundleURL: fakeBundle,
    applicationSupportURL: fakeLibrary,
    fileManager: .default
)
try require(release.mode == .release, "no-argument launch must select release mode")
try require(
    release.supportURL.lastPathComponent == "Mac Face Lock",
    "release data must use the product support directory"
)
```

Also prove `--source-root` and the legacy one-path form preserve the current repo layout, release mode copies the default config only when missing, and a support-directory symlink escaping the owned root is rejected.

- [ ] **Step 2: Compile and verify RED**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/AppEnvironment.swift tests/swift/AppEnvironmentTests.swift \
  -o /tmp/mac-face-lock-environment-tests
```

Expected: compile failure because `AppEnvironment.swift` is absent.

- [ ] **Step 3: Implement environment resolution and update consumers**

Keep `ProjectLocator` as the source-mode validator. Change `LocalJSONStore` naming from `projectURL` to `resourcesURL` without changing JSON behavior. Change `AppDelegate` to resolve `AppEnvironment` and pass its URLs to stores and controllers.

- [ ] **Step 4: Run Swift path suites**

Run both `AppEnvironmentTests` and the existing `ProjectLocatorTests`, then run:

```bash
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI -framework AVFoundation
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/app/AppEnvironment.swift src/app/ProjectLocator.swift src/app/AppDelegate.swift src/app/LocalJSONStore.swift tests/swift/AppEnvironmentTests.swift .github/workflows/ci.yml
git commit -m "feat: support release application data paths"
```

---

### Task 4: Add Persistent Onboarding State and Readiness Gates

**Files:**
- Create: `src/app/SetupModels.swift`
- Create: `src/app/SetupStore.swift`
- Create: `tests/swift/SetupStateTests.swift`
- Modify: `src/app/LocalJSONStore.swift`
- Modify: `src/app/Models.swift`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `SetupStep`, `SetupPermission`, `PermissionState`, `SetupCheck`, `OnboardingRecord`.
- Produces: `SetupReadiness.evaluate(permissions:ownerProfileValid:diagnosisPassed:ownerTestPassed:serviceHealthy:) -> SetupReadiness`.
- Produces `canEnableProtection`, which is true only when every required gate is true.

- [ ] **Step 1: Write failing gate tests**

```swift
let ready = SetupReadiness.evaluate(
    permissions: [.camera: .granted, .inputMonitoring: .granted, .accessibility: .granted],
    ownerProfileValid: true,
    diagnosisPassed: true,
    ownerTestPassed: true,
    serviceHealthy: true
)
try require(ready.canEnableProtection, "all required gates should enable protection")

let missingCamera = SetupReadiness.evaluate(
    permissions: [.camera: .denied, .inputMonitoring: .granted, .accessibility: .granted],
    ownerProfileValid: true,
    diagnosisPassed: true,
    ownerTestPassed: true,
    serviceHealthy: true
)
try require(!missingCamera.canEnableProtection, "denied camera must block protection")
```

Also test that screen recording is optional while screenshot evidence is disabled, unknown schema versions do not mark onboarding complete, and missing onboarding records default to incomplete.

For release mode, also prove that a missing onboarding record creates `control.json` with `protection_enabled: false`. Preserve the existing source-mode default so an upgrade does not silently change a running contributor installation.

- [ ] **Step 2: Compile and verify RED**

Run the new Swift test target.  
Expected: compile failure for missing setup types.

- [ ] **Step 3: Implement models and atomic persistence**

Store schema version `1`, current step, completed steps, completion timestamp, and app version in `data/onboarding.json`. Never persist a synthetic “granted” permission; live permission probes remain authoritative.

- [ ] **Step 4: Run setup and local-store tests**

Expected: all pass with no warnings.

- [ ] **Step 5: Commit**

```bash
git add src/app/SetupModels.swift src/app/SetupStore.swift src/app/LocalJSONStore.swift src/app/Models.swift tests/swift/SetupStateTests.swift .github/workflows/ci.yml
git commit -m "feat: persist safe onboarding readiness"
```

---

### Task 5: Implement the macOS Permission Center

**Files:**
- Create: `src/app/PermissionCenter.swift`
- Create: `tests/swift/PermissionStateTests.swift`
- Modify: `src/app/Info.plist`
- Modify: `scripts/build-status-app.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces protocol `PermissionProviding` for deterministic tests.
- Produces `PermissionCenter.refresh() async -> [SetupPermission: PermissionState]`.
- Produces `requestCamera() async`, `requestInputMonitoring()`, `requestAccessibility()`, `requestScreenRecording()`, and `openSettings(for:)`.
- Uses `AVCaptureDevice.authorizationStatus`, `CGPreflightListenEventAccess`, `AXIsProcessTrustedWithOptions`, and `CGPreflightScreenCaptureAccess`.

- [ ] **Step 1: Write failing permission-mapping tests**

Test `.notDetermined -> .notRequested`, `.restricted/.denied -> .denied`, `.authorized -> .granted`, and a granted permission requiring application restart -> `.restartRequired`.

- [ ] **Step 2: Compile and verify RED**

Expected: missing `PermissionCenter` symbols.

- [ ] **Step 3: Implement probes, requests, and settings links**

Add `NSCameraUsageDescription` to the visible application. Open only Apple-owned `x-apple.systempreferences:` privacy anchors, and fall back to the general Privacy & Security page if an anchor cannot be opened. Refresh on app activation and every two seconds while the permission step is visible.

- [ ] **Step 4: Typecheck with required frameworks**

Run:

```bash
xcrun swiftc -parse-as-library -typecheck src/app/*.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation \
  -framework ApplicationServices -framework CoreGraphics
```

Expected: success.

- [ ] **Step 5: Commit**

```bash
git add src/app/PermissionCenter.swift src/app/Info.plist scripts/build-status-app.sh tests/swift/PermissionStateTests.swift .github/workflows/ci.yml
git commit -m "feat: add live macOS permission center"
```

---

### Task 6: Run Enrollment and Diagnostics from the App

**Files:**
- Create: `src/app/RuntimeCommandRunner.swift`
- Create: `src/app/SetupCoordinator.swift`
- Create: `tests/swift/RuntimeCommandRunnerTests.swift`
- Create: `tests/swift/SetupCoordinatorTests.swift`
- Modify: `src/app/AppDelegate.swift`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces `RuntimeEvent: Decodable`.
- Produces `RuntimeCommandRunner.run(command:onEvent:) async throws -> RuntimeResult`.
- Produces `SetupCoordinator` published state for progress, current error, permission states, checks, and readiness.
- Runtime processes receive explicit `--resources-dir` and `--support-dir`.

- [ ] **Step 1: Write failing JSON-lines and coordinator tests**

Test valid progress events, malformed lines becoming an actionable runtime error, nonzero exit-code mapping, cancellation terminating the child process, and `enableProtection()` refusing to execute when one required gate is false.

- [ ] **Step 2: Compile and verify RED**

Expected: missing runner and coordinator symbols.

- [ ] **Step 3: Implement a bounded process runner**

Use `Process`, separate stdout/stderr pipes, a maximum line size of 256 KiB, a maximum retained stderr size of 1 MiB, and a single terminal continuation. Reject unsupported schema versions and unknown terminal events. Do not log face-template contents.

- [ ] **Step 4: Implement coordinator operations**

Expose:

- `refreshPermissions()`
- `startEnrollment()`
- `cancelEnrollment()`
- `runDiagnosis()`
- `verifyOwnerWithoutLocking()`
- `enableProtection()`

Map runtime exit codes to concise Chinese repair instructions.

- [ ] **Step 5: Run all Swift tests and typecheck**

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/app/RuntimeCommandRunner.swift src/app/SetupCoordinator.swift src/app/AppDelegate.swift tests/swift/RuntimeCommandRunnerTests.swift tests/swift/SetupCoordinatorTests.swift .github/workflows/ci.yml
git commit -m "feat: orchestrate enrollment and safe diagnostics"
```

---

### Task 7: Install and Repair the Release LaunchAgent

**Files:**
- Create: `src/app/ServiceManager.swift`
- Create: `tests/swift/ServiceManagerTests.swift`
- Create: `launchd/com.wuyi.mac-face-lock-release.plist`
- Modify: `src/app/SetupCoordinator.swift`
- Modify: `src/app/Models.swift`
- Modify: `agent.py`
- Modify: `scripts/build-status-app.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces `ServiceManaging` protocol.
- Produces `install(appURL:supportURL:) async throws`, `status() async -> ServiceStatus`, `restart()`, and `uninstallPreservingData()`.
- `ServiceStatus` includes the actual Agent process camera, input-monitoring, and accessibility readiness reported through `state.json`; visible-app permission probes never stand in for Agent permission health.
- Release label: `com.wuyi.mac-face-lock-agent`.
- LaunchAgent program points to `Mac Face Lock.app/Contents/Library/LoginItems/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent`.

- [ ] **Step 1: Write failing plist and rollback tests**

Test that rendered arguments use only application and support paths, never source or `.venv`; failed stable-health polling restores the previous plist; uninstall removes only the plist and running job; and a visible-app grant cannot satisfy readiness while Agent permission health is false.

- [ ] **Step 2: Compile and verify RED**

Expected: missing service manager symbols.

- [ ] **Step 3: Implement transactional user service management**

Use `launchctl bootout`, `bootstrap`, `enable`, and `kickstart` through bounded `Process` calls. Write the new plist to a sibling temporary file, preserve the prior plist, require three consecutive healthy polls with the same nonzero PID, and restore the prior job on failure. Start the Agent with protection disabled during onboarding; have the Agent publish its own permission readiness without opening the camera continuously.

- [ ] **Step 4: Connect service health to readiness**

The coordinator must install and verify the service before making the final “开启保护” action available. A moved app path must produce `.needsRepair`.

- [ ] **Step 5: Run service, packaging, and existing onboarding tests**

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/app/ServiceManager.swift src/app/SetupCoordinator.swift src/app/Models.swift agent.py launchd/com.wuyi.mac-face-lock-release.plist scripts/build-status-app.sh tests/swift/ServiceManagerTests.swift .github/workflows/ci.yml
git commit -m "feat: manage the bundled background service"
```

---

### Task 8: Build the First-Run and Operational Settings UI

**Files:**
- Create: `src/app/OnboardingView.swift`
- Create: `src/app/SettingsView.swift`
- Modify: `src/app/Views.swift`
- Modify: `src/app/DesktopWindowController.swift`
- Modify: `src/app/AppDelegate.swift`
- Modify: `src/app/StatusMenuController.swift`

**Interfaces:**
- `OnboardingView` consumes `SetupCoordinator` and `ThemeStore`.
- `SettingsView` consumes `SetupCoordinator`, `FaceLockStore`, and `ThemeStore`.
- `RootView` chooses onboarding until a valid completed record and live readiness are present.

- [ ] **Step 1: Add a failing structural UI policy test**

Extend `tests/test_packaging.py` to require the five onboarding step labels, operational settings section labels, and no shell-command copy in user-facing Swift sources.

Run: `python -m unittest tests.test_packaging.UnifiedPackagingTests.test_onboarding_sources_define_complete_customer_flow -v`  
Expected: failure because the new views do not exist.

- [ ] **Step 2: Implement the five onboarding screens**

Build:

- “准备检查”
- “权限中心”
- “录入本人”
- “安全测试”
- “完成并开启”

Every primary action displays in-progress, success, and failure states. Back navigation cannot skip a required gate. Closing and reopening resumes the last safe step. Enrollment has cancel and retry controls.

- [ ] **Step 3: Implement operational settings**

Move appearance controls out of `Views.swift` and add:

- “权限与运行状态”
- “本人资料”
- “保护规则”
- “服务诊断与修复”
- “外观”

Add “重新录入本人”, “刷新权限”, “打开系统设置”, “重新启动服务”, “重新安装服务”, and “查看日志”.

- [ ] **Step 4: Typecheck, build, and run packaging tests**

Run the Swift typecheck, `scripts/build-status-app.sh`, and `python -m unittest tests.test_packaging -v`.  
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/app/OnboardingView.swift src/app/SettingsView.swift src/app/Views.swift src/app/DesktopWindowController.swift src/app/AppDelegate.swift src/app/StatusMenuController.swift tests/test_packaging.py
git commit -m "feat: add guided first-run setup"
```

---

### Task 9: Import Existing Source-Beta Data Safely

> **Superseded on 2026-07-18:** The first open-source Beta does not ship automatic source-beta migration. The replacement implementation is `docs/superpowers/plans/2026-07-18-defer-source-beta-migration.md`. Existing source-beta data remains untouched and the release requires fresh enrollment.

**Files:**
- Create: `src/app/SourceDataMigrator.swift`
- Create: `tests/swift/SourceDataMigratorTests.swift`
- Modify: `src/app/SetupCoordinator.swift`
- Modify: `src/app/OnboardingView.swift`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces `discoverCandidates() -> [SourceInstallCandidate]`.
- Produces `import(candidate:destination:) throws -> MigrationResult`.
- Imports config, owner template, UI preferences, and activity history.
- Never modifies the source candidate.

- [ ] **Step 1: Write failing copy, validation, and rollback tests**

Test successful import, malformed template rejection, an injected failure after two copied files leaving the destination unchanged, and source-tree checksums remaining identical.

- [ ] **Step 2: Compile and verify RED**

Expected: missing migrator symbols.

- [ ] **Step 3: Implement staged import**

Copy allowed files into `backups/import-<UUID>/staging`, validate every file, then atomically replace destination files one by one with a rollback journal. Bound imported activity history to the existing 4 MiB scan budget.

- [ ] **Step 4: Add the optional import card to preparation**

The customer must explicitly choose “导入” or “跳过”. Skipping never deletes or marks the source installation.

- [ ] **Step 5: Run migration and full Swift tests**

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/app/SourceDataMigrator.swift src/app/SetupCoordinator.swift src/app/OnboardingView.swift tests/swift/SourceDataMigratorTests.swift .github/workflows/ci.yml
git commit -m "feat: import source beta data safely"
```

---

### Task 10: Freeze the Offline Runtime and Assemble the Release App

**Files:**
- Create: `requirements-build.txt`
- Create: `requirements-build-lock.txt`
- Create: `packaging/mac-face-lock-runtime.spec`
- Create: `scripts/build-runtime.sh`
- Create: `scripts/build-release.sh`
- Create: `tests/test_release_bundle.py`
- Modify: `scripts/build-app.sh`
- Modify: `scripts/build-status-app.sh`
- Modify: `src/agent-launcher/main.swift`
- Modify: `src/app/Info.plist`
- Modify: `.gitignore`

**Interfaces:**
- `requirements-build.txt` pins direct build dependency `PyInstaller==6.21.0`; `requirements-build-lock.txt` pins its complete resolved build dependency set.
- `scripts/build-runtime.sh` outputs `dist/runtime/MacFaceLockRuntime/`.
- `scripts/build-release.sh` outputs `dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip` and matching `.sha256`.
- Agent launcher receives `--resources-dir` and `--support-dir`, then executes embedded `MacFaceLockRuntime agent`.

- [ ] **Step 1: Write failing release-bundle tests**

Require:

- embedded runtime executable
- OpenCV Haar cascades
- NumPy and PyObjC runtime modules
- nested Agent app
- default config
- `LICENSE` and `THIRD_PARTY_NOTICES.md`
- build manifest with SHA-256 per shipped resource
- no developer-home absolute path, source path, `.venv`, or system-Python executable reference
- arm64 Mach-O and macOS 12 minimum for product executables

- [ ] **Step 2: Run and verify RED**

Run: `python -m unittest tests.test_release_bundle -v`  
Expected: failure because release build scripts and artifact do not exist.

- [ ] **Step 3: Add the reproducible PyInstaller build**

Use directory mode, target `arm64`, collect OpenCV data files and PyObjC hidden imports, and exclude tests and development tools. Set `PYTHONHASHSEED=0` and `MACOSX_DEPLOYMENT_TARGET=12.0`. Build from a clean Python 3.11 virtual environment using `requirements-lock.txt` and `requirements-build-lock.txt`; assert that every direct line in `requirements-build.txt` appears at the same version in the build lock.

- [ ] **Step 4: Assemble and sign the application**

Place runtime under `Contents/Resources/runtime`, Agent under `Contents/Library/LoginItems`, and default config under `Contents/Resources/defaults`. Generate `BuildManifest.json`, sign nested executable code before signing the outer app, and run `codesign --verify --deep --strict`.

- [ ] **Step 5: Zip and checksum**

Use `ditto -c -k --sequesterRsrc --keepParent` and `shasum -a 256`. Re-extract into a temporary directory and rerun bundle tests against the extracted app.

- [ ] **Step 6: Run release tests**

Run:

```bash
scripts/build-release.sh
python -m unittest tests.test_release_bundle tests.test_packaging tests.test_open_source_policy -v
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add requirements-build.txt requirements-build-lock.txt packaging/mac-face-lock-runtime.spec scripts/build-runtime.sh scripts/build-release.sh scripts/build-app.sh scripts/build-status-app.sh src/agent-launcher/main.swift src/app/Info.plist tests/test_release_bundle.py .gitignore
git commit -m "build: produce self-contained offline beta"
```

---

### Task 11: Extend CI and Release Safety Gates

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `tests/test_open_source_policy.py`
- Create: `.github/workflows/release-artifact.yml`

**Interfaces:**
- Pull requests run unit, Swift, typecheck, source bundle, and lightweight frozen-runtime import gates.
- Manual `workflow_dispatch` builds the unsigned offline artifact but does not publish it automatically.
- The workflow uploads the zip and checksum as Actions artifacts for inspection.

- [ ] **Step 1: Write failing workflow policy tests**

Require pinned Python 3.11, `PyInstaller==6.21.0`, macOS runner, build-release invocation, artifact upload, read-only repository permissions, and absence of a GitHub Release publishing token/action.

- [ ] **Step 2: Run and verify RED**

Run the focused open-source policy tests.  
Expected: missing workflow assertions fail.

- [ ] **Step 3: Implement workflows and gates**

Keep release publication manual until the extracted artifact passes a real fresh-user Mac acceptance run. Use Node 24-compatible official actions.

- [ ] **Step 4: Run policy tests**

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml .github/workflows/release-artifact.yml tests/test_open_source_policy.py
git commit -m "ci: validate offline release artifacts"
```

---

### Task 12: Update Documentation and Capture Real App Screens

**Files:**
- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `CHANGELOG.md`
- Modify: `THIRD_PARTY_NOTICES.md`
- Modify: `CONTRIBUTING.md`
- Create: `docs/customer-installation.md`
- Create: `docs/design-references/mac-face-lock-onboarding-permissions.png`
- Create: `docs/design-references/mac-face-lock-onboarding-enrollment.png`
- Modify: `tests/test_open_source_policy.py`

**Interfaces:**
- README starts with a customer download path and separately documents source development.
- Screenshots must be captured from the built application, not generated design references.

- [ ] **Step 1: Write failing documentation policy tests**

Require the Release download flow, right-click-open limitation, no-Codex/Python/Xcode/Terminal claim scoped to the release artifact, permission explanation, source-mode instructions, checksum verification, fail-open statement, no-liveness warning, and both screenshot image paths.

- [ ] **Step 2: Run and verify RED**

Expected: new documentation assertions fail.

- [ ] **Step 3: Update customer and contributor documentation**

Document exact install, onboarding, repair, uninstall-preserving-data, complete data deletion, source development, and build commands. Record PyInstaller 6.21.0 and its included license notices.

- [ ] **Step 4: Capture real screenshots**

Build the actual application, open the permission and enrollment screens with synthetic non-private state, capture only the app window, inspect both PNGs for private paths or personal data, then add them to README using relative Markdown image syntax.

- [ ] **Step 5: Run documentation and privacy gates**

Run `python -m unittest tests.test_open_source_policy -v` and inspect the tracked-file private-path scan.  
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add README.md SECURITY.md CHANGELOG.md THIRD_PARTY_NOTICES.md CONTRIBUTING.md docs/customer-installation.md docs/design-references/mac-face-lock-onboarding-permissions.png docs/design-references/mac-face-lock-onboarding-enrollment.png tests/test_open_source_policy.py
git commit -m "docs: publish customer onboarding guidance"
```

---

### Task 13: Full Verification and Release Candidate Handoff

**Files:**
- Modify only if a verification failure reveals an in-scope defect.

**Interfaces:**
- Produces a clean source test result, verified extracted release artifact, and a documented manual acceptance checklist.

- [ ] **Step 1: Run the complete automated suite**

```bash
python -m unittest discover -s tests -p 'test_*.py' -v
python -m compileall -q -x '/\.git/|/\.venv/|/dist/' .
bash -n scripts/*.sh scripts/*.command
```

Expected: all Python tests pass; compilation and shell parsing exit zero.

- [ ] **Step 2: Run all Swift suites and application typecheck**

Run every Swift test command declared in CI and:

```bash
xcrun swiftc -parse-as-library -typecheck src/app/*.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation \
  -framework ApplicationServices -framework CoreGraphics
```

Expected: all pass.

- [ ] **Step 3: Build and inspect the release**

```bash
scripts/build-release.sh
codesign --verify --deep --strict "dist/release/Mac Face Lock.app"
shasum -a 256 -c dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip.sha256
```

Expected: all validations pass.

- [ ] **Step 4: Perform fresh-user acceptance**

On an Apple Silicon test account without Codex, Python, Xcode, or source checkout: install offline, complete permissions, enroll, run no-lock verification, enable protection, restart, revoke and restore one permission, repair the service, and confirm source data is untouched.

- [ ] **Step 5: Record exact evidence**

Record test counts, artifact filename, SHA-256, app version, commit SHA, macOS version, and each manual checklist result in `docs/session-handoff.md`.

- [ ] **Step 6: Commit only verified handoff changes**

```bash
git add docs/session-handoff.md
git commit -m "chore: record offline beta verification"
```
