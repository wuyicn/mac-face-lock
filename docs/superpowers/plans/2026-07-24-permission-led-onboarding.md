# Permission-Led Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the blocking Safety Test onboarding step with a permission-led flow that completes after owner enrollment and required macOS permissions, then enables protection only when the background service is authoritatively healthy.

**Architecture:** Model onboarding completion and live protection readiness as two separate states. The onboarding record is complete when the active four-step journey and owner/permission prerequisites are satisfied; `control.json` remains disabled until the service reports healthy. Legacy `safety_test` records decode into the new permissions step, and a service failure routes a completed user to the existing main recovery interface instead of trapping them in onboarding.

**Tech Stack:** Swift 5, SwiftUI, AppKit, AVFoundation, macOS TCC permissions, local JSON state, launchd service management, Python `unittest`, shell-based release packaging.

## Global Constraints

- Work only in the isolated repository worktree on branch `codex/self-contained-onboarding`.
- Preserve the single visible `Mac Face Lock` identity for camera, Input Monitoring, Accessibility, onboarding, protection, and recovery.
- Do not reintroduce `Mac FaceLockRuntime`, a separately visible Agent permission identity, or a user-facing Safety Test.
- Never write `protection_enabled=true` until the current owner profile and required permissions are valid and the current service status is healthy.
- A service install, restart, status, persistence, cancellation, quit, or legacy-cleanup failure must leave protection disabled.
- Do not discard or rewrite unrelated work. Historical design and plan files remain historical records; update only current public guidance and current handoff material.
- Use test-driven development: add the focused failing test, run it and observe the expected failure, make the smallest implementation change, then rerun the focused test.
- Commit after every completed task with only that task's files.

---

### Task 1: Decode legacy onboarding state into the four-step model

**Files:**

- Modify: `src/app/SetupModels.swift`
- Modify: `src/app/SetupStore.swift`
- Modify: `tests/swift/SetupStateTests.swift`

- [ ] **Step 1: Add failing migration and completion tests**

Add these cases to `SetupStateTests.main()` and implement focused fixtures:

```swift
try testPermissionLedRecordRequiresOnlyActiveSteps()
try testLegacySafetyTestStepDecodesAsPermissions()
try testLegacyCompletedRecordRemainsComplete()
try testSetupStorePersistsOnlyActiveStepNames()
```

Assert:

```swift
let activeSteps: Set<SetupStep> = [
    .preparation, .enrollment, .permissions, .completion,
]
try require(
    Set(SetupStep.allCases) == activeSteps,
    "the active onboarding model still exposes a safety-test step"
)
```

Decode raw version-1 JSON containing `"current_step":"safety_test"` and assert
that it becomes `.permissions`. Decode an old completed record containing all
five old step strings and assert `isComplete == true` after normalization.
Save the decoded record again and assert the output contains no
`"safety_test"`.

- [ ] **Step 2: Run the setup-state test and confirm the red state**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift src/app/AppEnvironment.swift \
  src/app/Models.swift src/app/SetupModels.swift \
  src/app/LocalJSONStore.swift src/app/SetupStore.swift \
  tests/swift/SetupStateTests.swift \
  -o /tmp/mac-face-lock-setup-state-tests
/tmp/mac-face-lock-setup-state-tests
```

Expected: compilation or assertions fail because `.safetyTest` is still an
active case and legacy decoding is not normalized.

- [ ] **Step 3: Implement explicit legacy decoding**

Change the active model to:

```swift
enum SetupStep: String, CaseIterable, Hashable {
    case preparation
    case enrollment
    case permissions
    case completion
}
```

Give `SetupStep` an explicit `Codable` implementation. Decode
`"safety_test"` as `.permissions`; decode active values normally; reject other
unknown values through `DecodingError.dataCorruptedError`. Always encode the
active raw value, so a migrated record never writes `"safety_test"`.

Keep `OnboardingRecord.schemaVersion == 1`. Its completion predicate must
require:

```swift
Set(completedSteps).isSuperset(of: Set(SetupStep.allCases))
```

Deduplicate and normalize `completedSteps` when `SetupStore` loads or saves a
record. Preserve an already completed record's `completedAt`,
`ownerProfileFingerprint`, and `requiresOwnerReverification` values.

- [ ] **Step 4: Rerun the focused test**

Run the Step 2 command.

Expected: `Setup state tests passed`.

- [ ] **Step 5: Commit the state migration**

```bash
git add src/app/SetupModels.swift src/app/SetupStore.swift \
  tests/swift/SetupStateTests.swift
git commit -m "refactor: migrate onboarding to permission-led steps"
```

---

### Task 2: Separate onboarding completion readiness from protection readiness

**Files:**

- Modify: `src/app/SetupModels.swift`
- Modify: `src/app/SetupCoordinator.swift`
- Modify: `tests/swift/SetupStateTests.swift`

- [ ] **Step 1: Add failing readiness tests**

Replace the single-gate expectations with:

```swift
try testOwnerAndForegroundPermissionsCompleteOnboarding()
try testServiceHealthSeparatelyControlsProtection()
try testDiagnosisAndOwnerTestDoNotGateTheNewFlow()
try testScreenRecordingOnlyGatesWhenEvidenceIsEnabled()
```

For valid owner plus camera, Input Monitoring, and Accessibility:

```swift
let serviceDown = SetupReadiness.evaluate(
    permissions: grantedPermissions,
    agentPermissions: [
        .camera: .denied,
        .inputMonitoring: .denied,
        .accessibility: .denied,
    ],
    ownerProfileValid: true,
    diagnosisPassed: false,
    ownerTestPassed: false,
    serviceHealthy: false
)
try require(
    serviceDown.canCompleteOnboarding,
    "foreground permissions and a valid owner should complete onboarding"
)
try require(
    !serviceDown.canEnableProtection,
    "an unhealthy service must keep protection disabled"
)
```

Assert each missing required foreground permission and an invalid owner block
`canCompleteOnboarding`. Assert `diagnosisPassed=false` and
`ownerTestPassed=false` do not block either readiness state when all real
protection gates, including service health, are true.

- [ ] **Step 2: Run the setup-state test and confirm the red state**

Run the Task 1 Step 2 command.

Expected: compilation fails because `canCompleteOnboarding` does not exist, or
the assertions fail because diagnostic and service checks share one gate.

- [ ] **Step 3: Split the two readiness sets**

Refactor `SetupReadiness` to expose:

```swift
let onboardingRequiredChecks: Set<SetupCheck>
let protectionRequiredChecks: Set<SetupCheck>

var canCompleteOnboarding: Bool {
    onboardingRequiredChecks.allSatisfy { checks[$0] == true }
}

var canEnableProtection: Bool {
    protectionRequiredChecks.allSatisfy { checks[$0] == true }
}
```

The onboarding set contains camera, Input Monitoring, Accessibility, and owner
profile. Add screen recording only when screenshot evidence is enabled. The
protection set is the onboarding set plus service health. Keep diagnosis and
owner-test values in `checks` for internal diagnostics and compatibility, but
do not put them in either gate.

For the permission checks, use the current unified app's `permissionStates`.
Do not allow a missing or stale `serviceStatus` to overwrite current foreground
permission grants. Service-reported permission readiness remains part of
`ServiceStatus.isHealthy`, and therefore part of the separate service-health
gate.

Update `SetupCoordinator.updateReadiness()` to stop passing the old
service-derived permission map as the authority for onboarding permissions.

- [ ] **Step 4: Rerun the focused tests**

Run the Task 1 Step 2 command.

Expected: `Setup state tests passed`.

- [ ] **Step 5: Commit the readiness split**

```bash
git add src/app/SetupModels.swift src/app/SetupCoordinator.swift \
  tests/swift/SetupStateTests.swift
git commit -m "refactor: separate setup and protection readiness"
```

---

### Task 3: Migrate coordinator navigation to preparation, enrollment, permissions, completion

**Files:**

- Modify: `src/app/SetupCoordinator.swift`
- Modify: `tests/swift/SetupCoordinatorTests.swift`

- [ ] **Step 1: Add failing journey and restore tests**

Register focused tests in `SetupCoordinatorTests.main()`:

```swift
try await testPreparationAdvancesDirectlyToEnrollment()
try await testEnrollmentAdvancesToPermissions()
try await testPermissionsAdvanceToCompletion()
try testLegacySafetyTestRecordRestoresToPermissions()
try testLegacyPermissionsWithoutProfileRestoresToEnrollment()
try testBackNavigationUsesFourStepOrder()
```

The happy-path assertions are:

```swift
try require(subject.currentStep == .preparation, "unexpected initial step")
try require(await subject.prepareForSetup(), "preparation did not pass")
try require(subject.currentStep == .enrollment, "preparation skipped enrollment")

await subject.startEnrollment()
try require(subject.currentStep == .permissions, "enrollment did not reach permissions")

try require(
    await subject.continueFromPermissions(),
    "required permissions did not advance"
)
try require(subject.currentStep == .completion, "permissions did not reach completion")
```

Use a fake permission provider that grants camera for enrollment and all three
required permissions before `continueFromPermissions()`.

- [ ] **Step 2: Run the coordinator suite and confirm the red state**

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

Expected: new journey assertions fail against the old
preparation → permissions → enrollment → safety-test order.

- [ ] **Step 3: Implement the four-step transitions**

Make these transition changes:

```swift
prepareForSetup()
// persist .enrollment, completing .preparation

markEnrollmentCompleted()
// persist .permissions, completing .enrollment

continueFromPermissions()
// require camera + inputMonitoring + accessibility
// persist .completion, completing .permissions
```

`startEnrollment()` must request camera when its state is not granted, refresh
the camera state, and only then start the runtime. This is the only permission
prompt required before the permissions page.

Update `goBack()`:

```swift
.preparation -> nil
.enrollment  -> .preparation
.permissions -> .enrollment
.completion  -> .permissions
```

Update `safeRestoredStep` in the same order:

1. missing preparation → preparation;
2. missing enrollment or invalid owner profile → enrollment;
3. missing permissions → permissions;
4. otherwise → completion.

A decoded legacy `current_step=safety_test` is already `.permissions` from Task
1. Preserve old completed records. Remove all coordinator transitions and
recovery destinations that reference `.safetyTest`.

- [ ] **Step 4: Keep recovery mapping non-blocking**

Map failed prerequisites as follows:

```swift
missing permission -> .permissions
invalid owner       -> .enrollment
service unhealthy   -> .completion for incomplete records
service unhealthy   -> main recovery for completed records
```

`diagnosisPassed`, `ownerTestPassed`, and
`requiresOwnerReverification` must not send the user into a removed onboarding
step. For a valid stored profile, migrate `requiresOwnerReverification` to
`false` when the new flow completes; for an invalid profile, keep recovery at
enrollment.

Remove `runSafetyTest()` from the onboarding state machine. Internal
`runDiagnosis()` and owner verification helpers may remain for troubleshooting,
but no normal onboarding or restore path calls them.

- [ ] **Step 5: Rerun coordinator and setup-state suites**

Run the Task 3 Step 2 command, then the Task 1 Step 2 command.

Expected: both pass.

- [ ] **Step 6: Commit navigation migration**

```bash
git add src/app/SetupCoordinator.swift \
  tests/swift/SetupCoordinatorTests.swift
git commit -m "refactor: use permission-led setup navigation"
```

---

### Task 4: Complete onboarding before a non-blocking service enable attempt

**Files:**

- Modify: `src/app/SetupCoordinator.swift`
- Modify: `tests/swift/SetupCoordinatorTests.swift`

- [ ] **Step 1: Add failing completion outcome tests**

Introduce:

```swift
enum OnboardingCompletionOutcome: Equatable {
    case protectionEnabled
    case completedNeedsRecovery
}
```

Register these tests:

```swift
try await testCompletionEnablesProtectionWhenServiceIsHealthy()
try await testCompletionPersistsAndRecoversWhenServiceIsUnhealthy()
try await testCompletionDoesNotRunDiagnosisOrOwnerVerification()
try await testMissingPermissionDoesNotCompleteOnboarding()
try await testQuitDuringCompletionLeavesProtectionDisabled()
try await testLegacyCleanupBlockCannotCompleteOrTouchService()
try await testCompletedRecoveryEnableStillRequiresHealthyService()
```

For the non-blocking failure case, assert:

```swift
let outcome = try await subject.completeOnboardingAndAttemptProtection()
try require(outcome == .completedNeedsRecovery, "wrong completion outcome")
try require(subject.hasCompletedOnboarding, "onboarding was rolled back")
try require(subject.recoveryStep == .completion, "recovery was not exposed")
try require(
    !fixture.localStore.readControl().protectionEnabled,
    "failed service attempt enabled protection"
)
```

Also assert the fake runtime received neither `.diagnose` nor `.verifyOwner`.

- [ ] **Step 2: Run the coordinator suite and confirm the red state**

Run the Task 3 Step 2 command.

Expected: compilation fails because the completion outcome and method do not
exist.

- [ ] **Step 3: Implement atomic onboarding completion**

Add:

```swift
func completeOnboardingAndAttemptProtection() async throws
    -> OnboardingCompletionOutcome
```

Required order:

1. reject application quit and blocked legacy-cleanup state;
2. require enrollment to be idle;
3. refresh current unified-app permissions and inspect the owner profile;
4. require `readiness.canCompleteOnboarding`;
5. write `control.json` with protection disabled;
6. persist a completed record with active `SetupStep.allCases`, a stable
   `completedAt`, current profile fingerprint, and
   `requiresOwnerReverification=false`;
7. set `hasCompletedOnboarding=true`;
8. install/repair or inspect the release service using the existing serialized
   service-mutation permit;
9. refresh permissions and readiness;
10. if `readiness.canEnableProtection`, write protection enabled and return
    `.protectionEnabled`;
11. otherwise keep protection disabled, set `recoveryStep=.completion`, provide
    an actionable `currentError`, and return `.completedNeedsRecovery`.

The method must not call `probeRuntimeDiagnosis()`,
`verifyOwnerWithoutLockingInsidePermit()`, `runSafetyTest()`, or the old runtime
validation gate.

If persistence fails before the completed record is durable, leave onboarding
incomplete and throw. If service setup/status fails after completion is durable,
do not roll back onboarding; return `.completedNeedsRecovery`. At every quit,
cancellation, stale legacy-cleanup generation, or thrown service path, write
protection disabled before returning.

- [ ] **Step 4: Make normal recovery enable strict but test-free**

Refactor the existing `enableProtection()` used by the main window, status menu,
and Settings:

- refresh current permissions and owner profile;
- install/repair or refresh the service;
- require `readiness.canEnableProtection`;
- never run diagnose or owner verification;
- write protection enabled only after the final current-generation readiness
  check;
- on failure, preserve completed onboarding and route to the correct recovery
  location.

Keep the existing runtime/service/service-mutation serialization, legacy
cleanup generation checks, enrollment cancellation, application quit checks,
and rollback behavior around `control.json`.

- [ ] **Step 5: Rerun coordinator, quit, and service-manager tests**

Run the Task 3 Step 2 command, then:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ApplicationQuitCoordinator.swift \
  tests/swift/ApplicationQuitCoordinatorTests.swift \
  -o /tmp/mac-face-lock-quit-tests
/tmp/mac-face-lock-quit-tests

xcrun swiftc -parse-as-library -DTESTING \
  src/app/Models.swift src/app/ServiceManager.swift \
  tests/swift/ServiceManagerTests.swift \
  -o /tmp/mac-face-lock-service-manager-tests
/tmp/mac-face-lock-service-manager-tests
```

Expected: all three suites print their pass banners.

- [ ] **Step 6: Commit completion orchestration**

```bash
git add src/app/SetupCoordinator.swift \
  tests/swift/SetupCoordinatorTests.swift
git commit -m "feat: complete setup before service recovery"
```

---

### Task 5: Replace the Safety Test UI with permission status and completion recovery

**Files:**

- Modify: `src/app/OnboardingView.swift`
- Modify: `src/app/SettingsView.swift`
- Modify: `src/app/Views.swift`
- Modify: `src/app/StatusMenuController.swift`
- Modify: `tests/test_packaging.py`
- Modify: `tests/test_open_source_policy.py`
- Modify: `tests/test_release_bundle.py`

- [ ] **Step 1: Replace old source-contract tests with the new UI contract**

Update the Python tests so they require:

```python
for phrase in (
    '(.preparation, "准备检查"',
    '(.enrollment, "录入本人"',
    '(.permissions, "权限状态"',
    '(.completion, "完成并开启"',
    'Button("完成设置并开启保护")',
    "completeOnboardingAndAttemptProtection()",
):
    self.assertIn(phrase, onboarding)
```

And reject:

```python
for obsolete in (
    '(.safetyTest, "安全测试"',
    'Button("运行安全测试")',
    "await setupCoordinator.runSafetyTest()",
    "正在执行不锁屏安全测试",
):
    self.assertNotIn(obsolete, onboarding)
```

Require the completion button not to be disabled merely because
`isLiveReady == false`. It may be disabled while an action is working, the app
is quitting, or `canCompleteOnboarding == false`.

- [ ] **Step 2: Run the focused Python tests and confirm the red state**

Run:

```bash
python -m unittest discover -s tests -p 'test_packaging.py' -v
python -m unittest discover -s tests -p 'test_open_source_policy.py' -v
python -m unittest discover -s tests -p 'test_release_bundle.py' -v
```

Expected: assertions fail because the old Safety Test sidebar item, page,
button, and coordinator call still exist.

- [ ] **Step 3: Rebuild the onboarding UI**

Use this sidebar order:

```swift
private let orderedSteps: [(SetupStep, String, String)] = [
    (.preparation, "准备检查", "checklist"),
    (.enrollment, "录入本人", "faceid"),
    (.permissions, "权限状态", "hand.raised"),
    (.completion, "完成并开启", "checkmark.shield"),
]
```

Remove `safetyTestStep`, its switch branch, trace calls, progress copy, and
button. Update preparation copy to say camera will be requested when enrollment
starts.

The permission page must show current `PermissionCenter` state for:

- Mac Face Lock 摄像头;
- Mac Face Lock 输入监控;
- Mac Face Lock 辅助功能;
- 屏幕录制 only as optional when screenshot evidence is disabled.

Each missing permission keeps its existing request/open-System-Settings action.
Poll current permissions every two seconds while this page is visible. Its
continue button calls `continueFromPermissions()` and only advances when the
three required permissions and owner profile are valid.

- [ ] **Step 4: Make completion communicate both outcomes**

The completion page shows the three required permissions and owner profile as
the completion prerequisites. Show background service as a separate
“开启保护状态” row, not as a blocker to completing setup.

The button:

```swift
Button("完成设置并开启保护") {
    actionState = .working("正在完成设置并开启后台保护…")
    Task {
        do {
            switch try await setupCoordinator
                .completeOnboardingAndAttemptProtection() {
            case .protectionEnabled:
                actionState = .success("首次设置已完成，保护已开启")
            case .completedNeedsRecovery:
                actionState = .success(
                    "首次设置已完成；后台保护保持关闭，可在设置中恢复"
                )
            }
        } catch {
            actionState = .failure(
                setupCoordinator.currentError ?? "首次设置尚未完成"
            )
        }
    }
}
```

Do not disable it solely because the service is unhealthy. When onboarding
becomes complete, `RootView` must route to `mainReady` or `mainRecovery`.

- [ ] **Step 5: Remove Safety Test recovery controls from Settings**

Delete the “重新运行安全测试” button and `.safetyTest` recovery text. Recovery
copy must identify one of:

- required permission missing → open permission settings;
- owner profile missing → re-enroll;
- background service unavailable → repair/reinstall/retry protection.

After re-enrollment from Settings, success copy should direct the user to
restore permissions/protection, not rerun a Safety Test.

Keep `enableProtection()` in the overview, status menu, and Settings as the
strict completed-user recovery action.

- [ ] **Step 6: Typecheck and rerun the focused UI tests**

Run:

```bash
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics

python -m unittest discover -s tests -p 'test_packaging.py' -v
python -m unittest discover -s tests -p 'test_open_source_policy.py' -v
python -m unittest discover -s tests -p 'test_release_bundle.py' -v
```

Expected: Swift typecheck exits 0 and all focused Python suites pass.

- [ ] **Step 7: Commit the UI migration**

```bash
git add src/app/OnboardingView.swift src/app/SettingsView.swift \
  src/app/Views.swift src/app/StatusMenuController.swift \
  tests/test_packaging.py tests/test_open_source_policy.py \
  tests/test_release_bundle.py
git commit -m "feat: replace safety test with permission status"
```

---

### Task 6: Update current customer guidance without rewriting history

**Files:**

- Modify: `README.md`
- Modify: `docs/customer-installation.md`
- Modify: `docs/session-handoff.md`
- Modify: `tests/test_legacy_cleanup_policy.py`
- Modify: `tests/test_open_source_policy.py`

- [ ] **Step 1: Add failing documentation assertions**

Update current policy tests to require the customer sequence:

```text
准备检查 → 录入本人 → 权限状态 → 完成并开启
```

Require current public docs to explain:

- camera permission is requested when enrollment begins;
- after enrollment, enable camera, Input Monitoring, and Accessibility;
- setup can finish if the service needs repair;
- protection remains off until the service is healthy;
- no Codex, Python, Xcode, or Terminal is required.

Reject “运行安全测试” and “完成安全测试” in `README.md` and
`docs/customer-installation.md`.

- [ ] **Step 2: Run the documentation tests and confirm the red state**

Run:

```bash
python -m unittest discover -s tests -p 'test_open_source_policy.py' -v
python -m unittest discover -s tests -p 'test_legacy_cleanup_policy.py' -v
```

Expected: old setup wording fails the new assertions.

- [ ] **Step 3: Update only current guidance**

Revise:

- `README.md` quick start and permission recovery;
- `docs/customer-installation.md` first-run and troubleshooting;
- `docs/session-handoff.md` current behavior and acceptance checklist.

Do not edit older dated files under `docs/superpowers/specs/` or
`docs/superpowers/plans/`; their Safety Test language documents previous
designs and must remain auditable history.

- [ ] **Step 4: Rerun documentation and full Python suites**

Run:

```bash
python -m unittest discover -s tests -p 'test_open_source_policy.py' -v
python -m unittest discover -s tests -p 'test_legacy_cleanup_policy.py' -v
python -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: every suite passes.

- [ ] **Step 5: Commit current documentation**

```bash
git add README.md docs/customer-installation.md docs/session-handoff.md \
  tests/test_legacy_cleanup_policy.py tests/test_open_source_policy.py
git commit -m "docs: explain permission-led first run"
```

---

### Task 7: Run regression, build, install, and real-Mac acceptance

**Files:**

- Verify: all tracked source and test files
- Modify only if verified results are recorded: `docs/session-handoff.md`

- [ ] **Step 1: Run the complete automated test suite**

Run:

```bash
python -m unittest discover -s tests -p 'test_*.py' -v

xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift src/app/AppEnvironment.swift \
  src/app/Models.swift src/app/SetupModels.swift \
  src/app/LocalJSONStore.swift src/app/SetupStore.swift \
  tests/swift/SetupStateTests.swift \
  -o /tmp/mac-face-lock-setup-state-tests
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
  -o /tmp/mac-face-lock-setup-coordinator-tests
/tmp/mac-face-lock-setup-coordinator-tests

xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics
```

Then run every remaining Swift command from `.github/workflows/ci.yml`,
especially PermissionState, RuntimeCommandRunner, ServiceManager,
ApplicationQuitCoordinator, SecureFileTree, and LegacyInstallCleaner.

Expected: all binaries print their pass banners and typecheck exits 0.

- [ ] **Step 2: Scan for active-flow leftovers**

Run:

```bash
rg -n \
  'case safetyTest|\\.safetyTest|runSafetyTest|运行安全测试|完成安全测试' \
  src README.md docs/customer-installation.md docs/session-handoff.md tests
```

Expected: no active source, current public-doc, or active test references.
References inside dated historical plans/specifications are allowed and are not
included in this scan.

- [ ] **Step 3: Build and verify the release application**

Run:

```bash
scripts/build-runtime.sh
scripts/build-app.sh
codesign --verify --deep --strict "dist/Mac Face Lock.app"
plutil -lint "dist/Mac Face Lock.app/Contents/Info.plist"
```

Record the exact app version, build output path, code-sign result, and SHA-256:

```bash
shasum -a 256 "dist/Mac Face Lock.app/Contents/MacOS/Mac Face Lock"
```

Expected: build succeeds, signature verification succeeds, and the plist is
valid.

- [ ] **Step 4: Install the new build without retaining the old app**

Before replacement, confirm the built artifact and installed app identities.
Quit the installed app and stop the project-owned service through the existing
safe service path. Replace `/Applications/Mac Face Lock.app` with the newly
built app; do not preserve a second old application bundle. Launch only the new
application.

Do not manually delete user profile data or macOS TCC records. Use the app's
supported reset/recovery actions when a clean-onboarding fixture is required.

- [ ] **Step 5: Perform real-Mac onboarding acceptance**

Verify with the installed application:

1. sidebar shows exactly four steps;
2. “准备检查” advances to “录入本人”;
3. beginning enrollment requests camera permission when needed;
4. a successful five-pose enrollment reaches “权限状态”;
5. camera, Input Monitoring, and Accessibility each show their current state
   and open the correct System Settings page;
6. all required permissions advance to “完成并开启”;
7. no Safety Test page or button appears;
8. healthy service outcome enters the main ready interface and protection is
   enabled;
9. forced unhealthy-service outcome still completes onboarding, enters main
   recovery, and keeps protection disabled;
10. quitting or cancelling during enrollment/completion never enables
    protection or corrupts the previous owner profile.

- [ ] **Step 6: Inspect installed state and logs**

Verify the installed app, launchd plist, running executable path, local
`onboarding.json`, `control.json`, current service status, and recent logs all
refer to the same installed build. Acceptance requires:

- `onboarding.json` contains no `"safety_test"`;
- completed onboarding has all four active steps and a nonempty
  `completed_at`;
- `control.json` is true only for the healthy-service scenario;
- the unhealthy-service scenario is visible and actionable in the main
  interface;
- there is no separately visible old Agent app or old app bundle.

- [ ] **Step 7: Record evidence and commit only if documentation changed**

If acceptance evidence is added to `docs/session-handoff.md`, include the test
counts, app version, SHA-256, installed bundle path, service outcome, and the two
completion scenarios. Then:

```bash
git add docs/session-handoff.md
git commit -m "docs: record permission-led release acceptance"
```

If no tracked file changed, do not create an empty commit.

---

## Final Review Gate

- [ ] Compare the implementation against every acceptance item in
  `docs/superpowers/specs/2026-07-24-permission-led-onboarding-design.md`.
- [ ] Run `git status --short` and confirm there are no unintended files.
- [ ] Run `git diff --check`.
- [ ] Scan the implementation for placeholders:

```bash
rg -n 'TODO|FIXME|TBD|placeholder|fatalError\\(' src tests \
  README.md docs/customer-installation.md docs/session-handoff.md
```

- [ ] Confirm all public methods and test fakes compile consistently.
- [ ] Do not claim the issue fixed until automated tests, release build,
  installed-app identity, four-step real-Mac flow, and service-failure recovery
  have all been observed.
