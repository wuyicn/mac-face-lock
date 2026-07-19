# Enrollment Pose Guidance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make five-pose enrollment understandable and reliably completable by adding dynamic native guidance, a 120-second window, correct pose ordering, and a dedicated enrollment-timeout repair message.

**Architecture:** Keep recognition thresholds and template persistence unchanged. Convert the known Python enrollment timeout into a stable runtime protocol event, accept and localize that event in the Swift control center, and render pose-specific guidance from the existing `enrollmentPose` state.

**Tech Stack:** Python 3 `unittest`, JSON-lines runtime protocol, Swift 5, SwiftUI, macOS app bundle, shell release scripts.

## Global Constraints

- Default enrollment timeout is exactly 120 seconds.
- Runtime timeout event is exactly `enrollment_timeout` with status `error` and exit code 13.
- Pose order is exactly `front`, `left`, `right`, `up`, `down`.
- Low-head guidance is exactly `轻收下巴约 15–20°，不要弯腰或把脸完全低下去`.
- Do not loosen multiple-face, pose, lighting, or face-size quality thresholds.
- Do not add external images, animation files, network resources, or third-party dependencies.
- Cancellation, timeout, and failure must not persist an incomplete owner template.

---

### Task 1: Emit a dedicated runtime enrollment-timeout result

**Files:**
- Modify: `config/config.json:31`
- Modify: `runtime_cli.py:22-27,195-223`
- Test: `tests/test_config.py:42`
- Test: `tests/test_runtime_cli.py:365-380`

**Interfaces:**
- Consumes: the exact `RuntimeError` message emitted by `enroll_owner`: `Enrollment timed out before every configured pose was completed.`
- Produces: `EXIT_ENROLLMENT_TIMEOUT = 13` and a final JSON event `{"event":"enrollment_timeout","status":"error",...}`.

- [ ] **Step 1: Run the existing failing configuration and runtime tests**

Run:

```bash
.venv/bin/python -m unittest \
  tests.test_config.ConfigurationTests.test_config_loads \
  tests.test_runtime_cli.RuntimeCLITests.test_enrollment_timeout_uses_dedicated_repair_event \
  -v
```

Expected: both tests fail; the configuration reports `40` below `120`, and the runtime result returns exit code `20` instead of `13`.

- [ ] **Step 2: Change the release default to 120 seconds**

Replace the field in `config/config.json`:

```json
"enroll_timeout_seconds": 120,
```

- [ ] **Step 3: Add the dedicated exit code and exact timeout classifier**

Add beside the other constants in `runtime_cli.py`:

```python
EXIT_ENROLLMENT_TIMEOUT = 13
ENROLLMENT_TIMEOUT_MESSAGE = (
    "Enrollment timed out before every configured pose was completed."
)
```

Add before `main`:

```python
def _is_enrollment_timeout(error: RuntimeError) -> bool:
    return str(error) == ENROLLMENT_TIMEOUT_MESSAGE
```

Update the `RuntimeError` branch in `main`:

```python
except RuntimeError as exc:
    if _is_camera_error(exc):
        emit("camera_unavailable", "error", str(exc))
        return EXIT_PERMISSION_OR_CAMERA
    if _is_enrollment_timeout(exc):
        emit("enrollment_timeout", "error", str(exc))
        return EXIT_ENROLLMENT_TIMEOUT
    emit("runtime_failure", "error", str(exc))
    return EXIT_RUNTIME_FAILURE
```

- [ ] **Step 4: Run the focused tests**

Run:

```bash
.venv/bin/python -m unittest \
  tests.test_config.ConfigurationTests.test_config_loads \
  tests.test_runtime_cli.RuntimeCLITests.test_enrollment_timeout_uses_dedicated_repair_event \
  -v
```

Expected: `Ran 2 tests` and `OK`.

- [ ] **Step 5: Commit the runtime protocol change**

```bash
git add config/config.json runtime_cli.py tests/test_config.py tests/test_runtime_cli.py
git commit -m "fix: report enrollment timeout clearly"
```

---

### Task 2: Accept and localize the timeout in the Swift control center

**Files:**
- Modify: `src/app/RuntimeCommandRunner.swift:10-37,137-147`
- Modify: `src/app/SetupCoordinator.swift:2138-2152`
- Test: `tests/swift/RuntimeCommandRunnerTests.swift:320-365`
- Test: `tests/swift/SetupCoordinatorTests.swift:2050-2065`

**Interfaces:**
- Consumes: runtime terminal tuple `("enrollment_timeout", "error", 13)`.
- Produces: a validated enrollment result and the Chinese repair instruction `录入超时，请保持脸部居中并按照当前动作重试。`.

- [ ] **Step 1: Run the existing failing Swift tests**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift \
  src/app/AppEnvironment.swift \
  src/app/RuntimeCommandRunner.swift \
  tests/swift/RuntimeCommandRunnerTests.swift \
  -o /tmp/mac-face-lock-runtime-runner-tests &&
/tmp/mac-face-lock-runtime-runner-tests

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

Expected: the runner rejects `enrollment_timeout` or exit code 13, and the coordinator does not map code 13 to a message containing `录入超时`.

- [ ] **Step 2: Add the event to the enrollment allowlist**

Update `.enroll` in `RuntimeCommand.allowedEvents`:

```swift
return Set(
    [
        "enrollment_started",
        "enrollment_progress",
        "enrollment_complete",
        "enrollment_timeout",
    ] + failures
)
```

Update `.enroll` in `RuntimeCommand.terminalEvents`:

```swift
return Set(["enrollment_complete", "enrollment_timeout"] + failures)
```

- [ ] **Step 3: Validate the terminal event and exit-code pairing**

Add the tuple to the `.enroll` compatibility switch:

```swift
case ("enrollment_complete", "success", 0),
     ("enrollment_timeout", "error", 13),
     ("camera_unavailable", "error", 10),
     ("runtime_failure", "error", 20):
    return true
```

- [ ] **Step 4: Localize exit code 13**

Add to `SetupCoordinator.repairInstruction(for:)`:

```swift
case 13:
    return "录入超时，请保持脸部居中并按照当前动作重试。"
```

- [ ] **Step 5: Run the focused Swift tests**

Run the two commands from Step 1 again.

Expected: both test executables exit successfully and print their existing success summaries.

- [ ] **Step 6: Commit the Swift protocol change**

```bash
git add \
  src/app/RuntimeCommandRunner.swift \
  src/app/SetupCoordinator.swift \
  tests/swift/RuntimeCommandRunnerTests.swift \
  tests/swift/SetupCoordinatorTests.swift
git commit -m "fix: surface enrollment timeout recovery"
```

---

### Task 3: Add dynamic native pose examples

**Files:**
- Modify: `src/app/OnboardingView.swift:380-438,693-701`
- Modify: `tests/test_packaging.py:260-300`

**Interfaces:**
- Consumes: `setupCoordinator.enrollmentPose: String?` with `front`, `left`, `right`, `up`, or `down`.
- Produces: `EnrollmentPoseGuide`, a private SwiftUI view showing the current pose symbol, direction, title, and exact instruction.

- [ ] **Step 1: Add a failing UI source contract**

Add to `test_onboarding_sources_define_complete_customer_flow` in `tests/test_packaging.py`:

```python
for guidance in (
    "EnrollmentPoseGuide",
    "正脸 · 左转约 30° · 右转约 30° · 轻微抬头 · 轻微低头",
    "正对摄像头，脸部保持居中",
    "只转动头部约 30°，身体保持不动",
    "轻抬下巴约 15–20°，不要后仰身体",
    "轻收下巴约 15–20°，不要弯腰或把脸完全低下去",
):
    with self.subTest(enrollment_guidance=guidance):
        self.assertIn(guidance, onboarding)
```

- [ ] **Step 2: Run the source contract and verify RED**

Run:

```bash
.venv/bin/python -m unittest \
  tests.test_packaging.UnifiedPackagingTests.test_onboarding_sources_define_complete_customer_flow \
  -v
```

Expected: failure because `EnrollmentPoseGuide` and the guidance strings are absent.

- [ ] **Step 3: Correct the displayed pose order and embed the guide**

Replace the static sequence in `enrollmentStep`:

```swift
Text("正脸 · 左转约 30° · 右转约 30° · 轻微抬头 · 轻微低头")
```

Within `if let pose = setupCoordinator.enrollmentPose`, keep the current-action label and add:

```swift
EnrollmentPoseGuide(pose: pose)
```

- [ ] **Step 4: Add the private SwiftUI guide**

Add below `OnboardingCard` in `OnboardingView.swift`:

```swift
private struct EnrollmentPoseGuide: View {
    let pose: String

    private var symbol: String {
        switch pose {
        case "left": return "arrow.left"
        case "right": return "arrow.right"
        case "up": return "arrow.up"
        case "down": return "arrow.down"
        default: return "viewfinder"
        }
    }

    private var title: String {
        switch pose {
        case "left": return "向左转头"
        case "right": return "向右转头"
        case "up": return "轻微抬头"
        case "down": return "轻微低头"
        default: return "保持正脸"
        }
    }

    private var instruction: String {
        switch pose {
        case "left", "right":
            return "只转动头部约 30°，身体保持不动"
        case "up":
            return "轻抬下巴约 15–20°，不要后仰身体"
        case "down":
            return "轻收下巴约 15–20°，不要弯腰或把脸完全低下去"
        default:
            return "正对摄像头，脸部保持居中"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 36, weight: .medium))
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.tint)
                    .offset(x: 28, y: -28)
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 5) {
                Text("动作示例 · \(title)")
                    .font(.callout.weight(.semibold))
                Text(instruction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 5: Run the UI contract and Swift typecheck**

Run:

```bash
.venv/bin/python -m unittest \
  tests.test_packaging.UnifiedPackagingTests.test_onboarding_sources_define_complete_customer_flow \
  -v

xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics
```

Expected: the Python test passes and Swift typechecking exits with code 0.

- [ ] **Step 6: Commit the pose guide**

```bash
git add src/app/OnboardingView.swift tests/test_packaging.py
git commit -m "feat: guide each enrollment pose"
```

---

### Task 4: Verify, package, reinstall, and complete local acceptance

**Files:**
- Modify after successful verification: `docs/session-handoff.md`
- Generated and tracked by the existing release flow: `dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip`

**Interfaces:**
- Consumes: all changes from Tasks 1–3.
- Produces: a signed local beta app, preserved onboarding state with a 120-second timeout, and evidence that enrollment reaches the safety-test step.

- [ ] **Step 1: Run the complete automated suite**

Run:

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics
```

Expected: every Python test passes and Swift typechecking exits with code 0.

- [ ] **Step 2: Build and validate the release archive**

Run:

```bash
scripts/build-release.sh
shasum -a 256 dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip
```

Expected: the build script reports success, extracted release tests pass, and `shasum` prints one SHA-256 digest.

- [ ] **Step 3: Replace only the installed application**

Quit `Mac Face Lock`, extract the new archive into a fresh temporary directory, copy `Mac Face Lock.app` to `/Applications`, and verify:

```bash
codesign --verify --deep --strict "/Applications/Mac Face Lock.app"
```

Expected: code-sign verification exits with code 0. Do not delete `~/Library/Application Support/Mac Face Lock`.

- [ ] **Step 4: Update only the preserved timeout field**

Atomically change only `enroll_timeout_seconds` in:

```text
~/Library/Application Support/Mac Face Lock/config/config.json
```

Expected: the field is `120`; all other configuration fields and onboarding state are unchanged.

- [ ] **Step 5: Run visual and functional acceptance**

Open the installed app and verify:

1. The pose sequence reads `正脸 · 左转约 30° · 右转约 30° · 轻微抬头 · 轻微低头`.
2. The example card changes with the current pose.
3. The low-head step displays `轻收下巴约 15–20°，不要弯腰或把脸完全低下去`.
4. A successful five-pose run reaches `安全测试`.
5. If 120 seconds expires, the app displays a message containing `录入超时`, not `运行组件发生错误`.

- [ ] **Step 6: Record current artifact evidence**

Update `docs/session-handoff.md` with the verified test count, archive size, SHA-256, installed app result, and whether five-pose enrollment reached `安全测试`.

- [ ] **Step 7: Commit verified artifact evidence**

```bash
git add \
  docs/session-handoff.md \
  dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip
git commit -m "docs: refresh enrollment guidance release"
```

- [ ] **Step 8: Push the existing branch and refresh the draft PR**

```bash
git push origin codex/self-contained-onboarding
```

Expected: `origin/codex/self-contained-onboarding` points to the verified release-evidence commit. Update draft PR #2 with the new test count, archive size, SHA-256, and local acceptance status.
