# Onboarding Sidebar Version Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display the installed Mac Face Lock marketing version as `v0.2.0` at the bottom-left of the first-run onboarding sidebar.

**Architecture:** Add a small pure formatter that converts `CFBundleShortVersionString` into optional display text and lets the onboarding view decide whether to render it. Keep version lookup independent of `SetupCoordinator`, preserve the existing sidebar layout, and omit the label when bundle metadata is missing or empty.

**Tech Stack:** Swift 5, SwiftUI, Foundation `Bundle`, Python `unittest`, shell-based macOS build and code-signing gates.

## Global Constraints

- Only the first-run onboarding sidebar changes; main views, settings, status menu, release version, and release process remain unchanged.
- Display format is exactly `v<CFBundleShortVersionString>`, producing `v0.2.0` for the current bundle.
- The concrete version must not be hard-coded in Swift UI source.
- Missing, non-string, whitespace-only, or empty metadata produces no label.
- The version sits below the local-storage statement, left aligned, in a smaller and lower-contrast style.
- Existing sidebar width, step list, application-support data, permissions, service state, and protection state remain unchanged.

---

### Task 1: Version display formatter and executable Swift test

**Files:**
- Create: `src/app/AppVersionDisplay.swift`
- Create: `tests/swift/AppVersionDisplayTests.swift`
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") -> Any?`.
- Produces: `AppVersionDisplay.text(from rawValue: Any?) -> String?` and `AppVersionDisplay.current -> String?`.

- [ ] **Step 1: Write the failing formatter test**

Create `tests/swift/AppVersionDisplayTests.swift`:

```swift
import Foundation

private enum TestFailure: Error {
    case assertion(String)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure.assertion(message)
    }
}

@main
struct AppVersionDisplayTests {
    static func main() throws {
        try require(
            AppVersionDisplay.text(from: "0.2.0") == "v0.2.0",
            "marketing version should use the selected v-prefix format"
        )
        try require(
            AppVersionDisplay.text(from: " 0.2.0 ") == "v0.2.0",
            "version metadata should be trimmed"
        )
        try require(AppVersionDisplay.text(from: nil) == nil, "missing metadata must be hidden")
        try require(AppVersionDisplay.text(from: "   ") == nil, "blank metadata must be hidden")
        try require(AppVersionDisplay.text(from: 200) == nil, "non-string metadata must be hidden")
        print("App version display tests passed")
    }
}
```

- [ ] **Step 2: Run the test to verify RED**

Run:

```bash
xcrun swiftc -parse-as-library \
  tests/swift/AppVersionDisplayTests.swift \
  -o /tmp/mac-face-lock-version-display-tests
```

Expected: compilation fails because `AppVersionDisplay` does not exist.

- [ ] **Step 3: Add the minimal formatter**

Create `src/app/AppVersionDisplay.swift`:

```swift
import Foundation

enum AppVersionDisplay {
    static func text(from rawValue: Any?) -> String? {
        guard let rawVersion = rawValue as? String else {
            return nil
        }
        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            return nil
        }
        return "v\(version)"
    }

    static var current: String? {
        text(
            from: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            )
        )
    }
}
```

- [ ] **Step 4: Run the formatter test to verify GREEN**

Run:

```bash
xcrun swiftc -parse-as-library \
  src/app/AppVersionDisplay.swift \
  tests/swift/AppVersionDisplayTests.swift \
  -o /tmp/mac-face-lock-version-display-tests
/tmp/mac-face-lock-version-display-tests
```

Expected: `App version display tests passed`.

- [ ] **Step 5: Register the Swift test in CI and local verification docs**

Add a `Run Swift app-version display tests` step after the full Python suite in `.github/workflows/ci.yml` using the exact compile-and-run command from Step 4 with output under `$RUNNER_TEMP/mac-face-lock-version-display-tests`. Add the same command to the `README.md` complete-test block using `/tmp/mac-face-lock-version-display-tests`.

- [ ] **Step 6: Run policy and formatter tests**

Run:

```bash
.venv/bin/python -m unittest tests.test_open_source_policy tests.test_packaging -v
xcrun swiftc -parse-as-library \
  src/app/AppVersionDisplay.swift \
  tests/swift/AppVersionDisplayTests.swift \
  -o /tmp/mac-face-lock-version-display-tests
/tmp/mac-face-lock-version-display-tests
```

Expected: all Python tests pass and the Swift runner prints `App version display tests passed`.

- [ ] **Step 7: Commit the formatter and test harness**

```bash
git add src/app/AppVersionDisplay.swift tests/swift/AppVersionDisplayTests.swift \
  .github/workflows/ci.yml README.md
git commit -m "test: cover onboarding version display"
```

---

### Task 2: Render the dynamic version in the onboarding sidebar

**Files:**
- Modify: `tests/test_packaging.py`
- Modify: `src/app/OnboardingView.swift:169-178`

**Interfaces:**
- Consumes: `AppVersionDisplay.current -> String?` from Task 1.
- Produces: an optional `Text(versionText)` beneath the local-storage statement in `OnboardingView.stepSidebar`.

- [ ] **Step 1: Write the failing sidebar integration test**

Add this test to `UnifiedPackagingTests` in `tests/test_packaging.py`:

```python
def test_onboarding_sidebar_uses_dynamic_bundle_version_label(self) -> None:
    onboarding = (PROJECT_DIR / "src/app/OnboardingView.swift").read_text()
    version_display = (PROJECT_DIR / "src/app/AppVersionDisplay.swift").read_text()

    self.assertIn("if let versionText = AppVersionDisplay.current", onboarding)
    self.assertIn("Text(versionText)", onboarding)
    self.assertIn(".font(.caption2)", onboarding)
    self.assertIn("CFBundleShortVersionString", version_display)
    self.assertNotIn('Text("v0.2.0")', onboarding)
```

- [ ] **Step 2: Run the integration test to verify RED**

Run:

```bash
.venv/bin/python -m unittest \
  tests.test_packaging.UnifiedPackagingTests.test_onboarding_sidebar_uses_dynamic_bundle_version_label \
  -v
```

Expected: FAIL because `OnboardingView` does not reference `AppVersionDisplay.current`.

- [ ] **Step 3: Add the sidebar label**

Replace the existing bottom privacy `Text` block in `stepSidebar` with:

```swift
VStack(alignment: .leading, spacing: 8) {
    Text("所有人脸资料和运行记录只保存在本机。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

    if let versionText = AppVersionDisplay.current {
        Text(versionText)
            .font(.caption2)
            .foregroundStyle(Color.secondary.opacity(0.72))
    }
}
.padding(28)
```

- [ ] **Step 4: Run the integration and formatter tests to verify GREEN**

Run:

```bash
.venv/bin/python -m unittest \
  tests.test_packaging.UnifiedPackagingTests.test_onboarding_sidebar_uses_dynamic_bundle_version_label \
  -v
xcrun swiftc -parse-as-library \
  src/app/AppVersionDisplay.swift \
  tests/swift/AppVersionDisplayTests.swift \
  -o /tmp/mac-face-lock-version-display-tests
/tmp/mac-face-lock-version-display-tests
```

Expected: both test commands pass.

- [ ] **Step 5: Type-check and build the unified app**

Run:

```bash
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics
scripts/build-status-app.sh
codesign --verify --deep --strict "dist/Mac Face Lock.app"
```

Expected: type-check succeeds, the build prints the app path, and `codesign` returns success.

- [ ] **Step 6: Commit the sidebar integration**

```bash
git add tests/test_packaging.py src/app/OnboardingView.swift
git commit -m "feat: show version in onboarding sidebar"
```

---

### Task 3: Full verification, stable build, and installed-app acceptance

**Files:**
- Verify only: `dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip`
- Replace recoverably: `/Applications/OPC/Mac Face Lock.app`
- Preserve: `/Users/wuyi-macs/Library/Application Support/Mac Face Lock`

**Interfaces:**
- Consumes: committed formatter and sidebar integration from Tasks 1-2.
- Produces: a stable-signed installed app whose sidebar visibly displays `v0.2.0` while retaining the unified permission identity.

- [ ] **Step 1: Run the complete source verification**

Run:

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
xcrun swiftc -parse-as-library \
  src/app/AppVersionDisplay.swift \
  tests/swift/AppVersionDisplayTests.swift \
  -o /tmp/mac-face-lock-version-display-tests
/tmp/mac-face-lock-version-display-tests
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics
git diff --check
```

Expected: Python suite passes with only the declared release-artifact skip, the Swift runner passes, type-check succeeds, and `git diff --check` is silent.

- [ ] **Step 2: Build the release with the available stable Apple identity**

Run:

```bash
export MAC_FACE_LOCK_SIGNING_IDENTITY="$(
  security find-identity -v -p codesigning |
    sed -n 's/.*"\(Apple Development:.*\)"/\1/p' |
    head -n 1
)"
test -n "$MAC_FACE_LOCK_SIGNING_IDENTITY"
scripts/build-release.sh
shasum -a 256 dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip
codesign --verify --deep --strict "dist/Mac Face Lock.app"
```

Expected: release build and extracted-artifact gates pass; the app satisfies its designated requirement.

- [ ] **Step 3: Record safe live-state invariants before replacement**

Run:

```bash
support="$HOME/Library/Application Support/Mac Face Lock"
shasum -a 256 \
  "$support/data/owner_face.npy" \
  "$support/data/onboarding.json" \
  "$support/data/control.json" \
  "$support/config/config.json"
/usr/bin/python3 - "$support/data/state.json" "$support/data/control.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
control = json.load(open(sys.argv[2]))
assert state["camera_ready"] is True
assert state["input_monitoring_ready"] is True
assert state["accessibility_ready"] is True
assert control["protection_enabled"] is False
print("live preflight ready; protection remains disabled")
PY
```

Expected: four hashes are recorded, all three readiness fields are true, and protection is false.

- [ ] **Step 4: Replace the app recoverably without resetting TCC**

Run from the clean worktree after recording a unique timestamp:

```bash
stamp="$(date +%Y%m%d-%H%M%S)"
staged="/Applications/OPC/.Mac Face Lock.app.staged-$stamp"
backup="/Applications/OPC/Mac Face Lock.app.backup-$stamp"
ditto "dist/Mac Face Lock.app" "$staged"
codesign --verify --deep --strict "$staged"
launchctl bootout "gui/$(id -u)/com.wuyi.mac-face-lock-background" || true
ui_pids="$(ps -axo pid=,command= | awk '$0 ~ /\/Applications\/OPC\/Mac Face Lock\.app\/Contents\/MacOS\/MacFaceLock$/ {print $1}')"
for pid in $ui_pids; do kill -TERM "$pid"; done
.venv/bin/python scripts/atomic-swap.py \
  "$staged" "/Applications/OPC/Mac Face Lock.app"
mv "$staged" "$backup"
codesign --verify --deep --strict "/Applications/OPC/Mac Face Lock.app"
open "/Applications/OPC/Mac Face Lock.app"
```

Expected: the previous app remains at the timestamped backup path; no `tccutil reset` command is run.

- [ ] **Step 5: Verify the installed app and live permission continuity**

After the app recreates its background job, run:

```bash
support="$HOME/Library/Application Support/Mac Face Lock"
launchctl print "gui/$(id -u)/com.wuyi.mac-face-lock-background"
/usr/bin/python3 - "$support/data/state.json" "$support/data/control.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
control = json.load(open(sys.argv[2]))
assert state["camera_ready"] is True
assert state["input_monitoring_ready"] is True
assert state["accessibility_ready"] is True
assert control["protection_enabled"] is False
print("installed app retains all permissions with protection disabled")
PY
codesign -dv --verbose=4 "/Applications/OPC/Mac Face Lock.app" 2>&1 |
  grep -E '^(Identifier|TeamIdentifier|Authority)='
```

Expected: the background job has a live PID, all three permission fields remain true, protection remains false, and the stable Team ID is present.

- [ ] **Step 6: Perform visual acceptance**

Open the installed app and inspect the onboarding sidebar with Computer Use. Verify all of the following:

1. `v0.2.0` appears below the local-storage statement at the bottom-left.
2. The version is left aligned, smaller, and lower contrast than the statement.
3. The text is not truncated in the current window size.
4. The five onboarding steps and main content have not shifted horizontally.
5. Light and dark appearances both retain readable contrast.

Expected: all five checks pass in the actual `/Applications/OPC/Mac Face Lock.app` UI.

