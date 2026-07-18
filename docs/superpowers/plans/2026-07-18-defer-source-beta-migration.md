# Defer Source-Beta Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove automatic source-beta discovery and migration from the first open-source Beta while leaving every legacy directory untouched and requiring enrollment in the release onboarding flow.

**Architecture:** Add a policy regression test first, then reverse the three Task 9 product commits with a new non-destructive commit and replace the import UI with a static legacy-data notice. Keep the Task 8 onboarding, permission, enrollment, safety-test, and service-health gates unchanged. Update the original design and plan so future work treats automatic migration as deferred rather than partially implemented.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Python 3.11 `unittest`, GitHub Actions, macOS 12.0 build target

## Global Constraints

- The application must not discover, read, copy, import, recover, delete, rename, or mark source-beta data.
- Existing source-beta configuration, face templates, preferences, activity history, repositories, and LaunchAgents must remain untouched.
- The preparation screen must show exactly: `如果您使用过源码测试版，本版本不会自动读取或迁移旧数据。请重新录入本人并完成安全测试；原目录和数据将保持不变。`
- The customer must not be asked to choose “导入” or “跳过”.
- A new release onboarding must proceed from preparation to permissions and then enrollment; an old source-beta face template must not skip release enrollment.
- Protection must remain disabled until the current release completes enrollment, owner verification, required permissions, safety testing, and live service health.
- Do not expose Codex, shell commands, developer paths, `.venv`, or source repository paths in customer-facing UI.
- Keep `MACOSX_DEPLOYMENT_TARGET=12.0` and the existing `arm64-apple-macosx12.0` Swift targets.
- Preserve the Task 9 commits in Git history; do not use `git reset`, `git rebase`, or destructive checkout to erase them.
- Do not begin Task 10 frozen-runtime packaging in this plan.

---

### Task 1: Withdraw the Automatic Migration Runtime

**Files:**
- Create: `tests/test_no_legacy_migration.py`
- Modify: `src/app/OnboardingView.swift`
- Modify: `src/app/SetupCoordinator.swift`
- Modify: `.github/workflows/ci.yml`
- Delete: `src/app/SourceDataMigrator.swift`
- Delete: `tests/swift/SourceDataMigratorTests.swift`
- Modify: `tests/swift/SetupCoordinatorTests.swift`
- Modify: `tests/test_packaging.py`
- Modify: `src/app/ThemeStore.swift`

**Interfaces:**
- Consumes: the Task 8 `SetupCoordinator.prepareForSetup() async -> Bool`, `continueFromPermissions() async -> Bool`, enrollment, safety-test, and service-health flows.
- Produces: a preparation screen with a static `legacySourceBetaNotice` and no migration-related runtime types or methods.

- [ ] **Step 1: Add the failing no-migration policy test**

Create `tests/test_no_legacy_migration.py`:

```python
#!/usr/bin/env python3
from __future__ import annotations

import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
NOTICE = (
    "如果您使用过源码测试版，本版本不会自动读取或迁移旧数据。"
    "请重新录入本人并完成安全测试；原目录和数据将保持不变。"
)


class LegacyMigrationDeferralTests(unittest.TestCase):
    def test_release_onboarding_defers_automatic_source_beta_migration(self) -> None:
        onboarding = (PROJECT_DIR / "src/app/OnboardingView.swift").read_text()
        coordinator = (PROJECT_DIR / "src/app/SetupCoordinator.swift").read_text()
        workflow = (PROJECT_DIR / ".github/workflows/ci.yml").read_text()

        self.assertIn(NOTICE, onboarding)
        self.assertFalse((PROJECT_DIR / "src/app/SourceDataMigrator.swift").exists())
        self.assertFalse(
            (PROJECT_DIR / "tests/swift/SourceDataMigratorTests.swift").exists()
        )

        combined = onboarding + coordinator + workflow
        for forbidden in (
            "SourceDataMigrator",
            "SourceInstallCandidate",
            "migrationDecision",
            "importSourceData",
            "skipSourceDataImport",
            "retryMigrationRecovery",
            "发现旧版源码数据",
            "导入旧版数据",
            "跳过导入",
            "source-data-migration",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, combined)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the policy test and verify RED**

Run:

```bash
.venv/bin/python -m unittest tests.test_no_legacy_migration -v
```

Expected: FAIL because the notice is absent, `SourceDataMigrator.swift` and its Swift tests exist, and migration symbols remain in the UI, coordinator, and CI workflow.

- [ ] **Step 3: Reverse the Task 9 product commits without rewriting history**

Run from the isolated worktree:

```bash
git revert --no-commit 46b0ec7 6f535bd 569f28b
```

Resolve only conflicts caused by the new policy test. The resulting working tree must:

- delete `src/app/SourceDataMigrator.swift`;
- delete `tests/swift/SourceDataMigratorTests.swift`;
- restore `SetupCoordinator` to the Task 8 state at `25d9c51`;
- restore `OnboardingView` to the Task 8 state before the import/recovery cards;
- remove the migration Swift target and `SourceDataMigrator.swift` dependency from `.github/workflows/ci.yml`;
- remove migration-specific `SetupCoordinatorTests`;
- remove migration-specific string assertions from `tests/test_packaging.py`.

Do not revert `73ad965` or the approved 2026-07-18 design.

- [ ] **Step 4: Add the static source-beta notice**

In `src/app/OnboardingView.swift`, add this view:

```swift
private var legacySourceBetaNotice: some View {
    VStack(alignment: .leading, spacing: 8) {
        Label("源码测试版数据", systemImage: "archivebox")
            .font(.headline)
        Text("如果您使用过源码测试版，本版本不会自动读取或迁移旧数据。请重新录入本人并完成安全测试；原目录和数据将保持不变。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .background(
        Color.primary.opacity(0.05),
        in: RoundedRectangle(cornerRadius: 12)
    )
}
```

Render `legacySourceBetaNotice` in `preparationStep` after the four `SetupRequirementRow` values and before `CustomerActionStatusView`.

The notice has no button, path, scanner, file access, or state dependency.

- [ ] **Step 5: Verify the release always continues through enrollment**

In `tests/swift/SetupCoordinatorTests.swift`, preserve or add a focused test with this behavior:

```swift
let prepared = await coordinator.prepareForSetup()
try require(prepared, "preparation did not continue without a migration choice")
try require(
    coordinator.currentStep == .permissions,
    "preparation did not advance to permissions"
)

let continued = await coordinator.continueFromPermissions()
try require(continued, "granted camera permission did not continue")
try require(
    coordinator.currentStep == .enrollment,
    "release onboarding skipped required enrollment"
)
```

The fixture must use a fresh release support directory and a granted control-app camera permission. It must not construct a source migrator or source candidate.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run:

```bash
.venv/bin/python -m unittest \
  tests.test_no_legacy_migration \
  tests.test_packaging -v
```

Expected: PASS with zero failures.

Compile and run the coordinator suite without migration sources:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift src/app/AppEnvironment.swift \
  src/app/Models.swift src/app/SetupModels.swift \
  src/app/LocalJSONStore.swift src/app/SetupStore.swift \
  src/app/PermissionCenter.swift src/app/RuntimeCommandRunner.swift \
  src/app/ServiceManager.swift src/app/SetupCoordinator.swift \
  tests/swift/SetupCoordinatorTests.swift \
  -framework AppKit -framework AVFoundation \
  -framework ApplicationServices -framework CoreGraphics \
  -o /tmp/mac-face-lock-setup-coordinator-tests
/tmp/mac-face-lock-setup-coordinator-tests
```

Expected: PASS with no migration symbol or missing-file compiler errors.

- [ ] **Step 7: Typecheck the application**

Run:

```bash
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI \
  -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics
```

Expected: exit 0 with no warnings or errors introduced by this task.

- [ ] **Step 8: Commit the runtime withdrawal**

Run:

```bash
git add .github/workflows/ci.yml \
  src/app/OnboardingView.swift src/app/SetupCoordinator.swift \
  src/app/ThemeStore.swift tests/swift/SetupCoordinatorTests.swift \
  tests/test_packaging.py tests/test_no_legacy_migration.py
git add -u src/app/SourceDataMigrator.swift \
  tests/swift/SourceDataMigratorTests.swift
git diff --cached --check
git commit -m "refactor: defer automatic source beta migration"
```

Expected: one new commit that removes the automatic migration runtime without rewriting the earlier Task 9 history.

---

### Task 2: Align Documentation and Run Release Acceptance

**Files:**
- Modify: `docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md`
- Modify: `docs/superpowers/plans/2026-07-17-self-contained-onboarding.md`
- Verify: `docs/superpowers/specs/2026-07-18-defer-source-beta-migration-design.md`
- Verify: `.github/workflows/ci.yml`
- Verify: `src/app/OnboardingView.swift`
- Verify: `src/app/SetupCoordinator.swift`

**Interfaces:**
- Consumes: Task 1 final source tree with no automatic migration runtime.
- Produces: one unambiguous documentation path stating that Task 9 migration is deferred and Task 10 frozen-runtime packaging is next.

- [ ] **Step 1: Replace the original migration design section**

In `docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md`, replace the `## 已有源码版迁移` section with:

```markdown
## 已有源码版数据

首个开源 Beta 不自动发现、读取、复制或迁移源码测试版数据。

首次设置固定提示：

> 如果您使用过源码测试版，本版本不会自动读取或迁移旧数据。请重新录入本人并完成安全测试；原目录和数据将保持不变。

用户不需要选择“导入”或“跳过”。旧配置、本人模板、界面偏好、活动记录、源码仓库和 LaunchAgent 保持原样。发行版继续执行权限检查、重新录入本人、安全测试和后台服务健康验证。

完整决策见 `docs/superpowers/specs/2026-07-18-defer-source-beta-migration-design.md`。
```

- [ ] **Step 2: Mark the original Task 9 as superseded**

Immediately below `### Task 9: Import Existing Source-Beta Data Safely` in `docs/superpowers/plans/2026-07-17-self-contained-onboarding.md`, add:

```markdown
> **Superseded on 2026-07-18:** The first open-source Beta does not ship automatic source-beta migration. The replacement implementation is `docs/superpowers/plans/2026-07-18-defer-source-beta-migration.md`. Existing source-beta data remains untouched and the release requires fresh enrollment.
```

Do not rewrite the historical Task 9 steps; the note explains why the committed implementation was later withdrawn.

- [ ] **Step 3: Verify documentation has one active policy**

Run:

```bash
rg -n "已有源码版迁移|应用检测到现有源码安装时，向导提供导入" \
  docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md
rg -n "Superseded on 2026-07-18|2026-07-18-defer-source-beta-migration" \
  docs/superpowers/plans/2026-07-17-self-contained-onboarding.md \
  docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md
```

Expected: the first command returns no matches; the second command finds the superseding plan and design references.

- [ ] **Step 4: Run the complete Python and policy suite**

Run:

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
.venv/bin/python -m compileall -q -x '/\.git/|/\.venv/|/dist/' .
bash -n scripts/*.sh scripts/*.command
```

Expected: all unit tests pass, Python compilation exits 0, and every shell entry point parses.

- [ ] **Step 5: Build and verify both applications**

Run:

```bash
scripts/build-app.sh
scripts/build-status-app.sh
plutil -lint \
  src/app/Info.plist \
  launchd/com.wuyi.mac-face-lock-agent.plist \
  launchd/com.wuyi.mac-face-lock-release.plist \
  launchd/com.wuyi.mac-face-lock-status.plist \
  "dist/Mac Face Lock Agent.app/Contents/Info.plist" \
  "dist/Mac Face Lock.app/Contents/Info.plist"
codesign --verify --deep --strict "dist/Mac Face Lock Agent.app"
codesign --verify --deep --strict "dist/Mac Face Lock.app"
```

Expected: both builds exit 0; all six plists are valid; both signatures verify.

- [ ] **Step 6: Verify macOS floor, open-source policy, and clean diff**

Run:

```bash
for executable in \
  "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent" \
  "dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock"
do
  build_info="$(xcrun vtool -show-build "$executable")"
  minos="$(awk '$1 == "minos" { print $2; exit }' <<<"$build_info")"
  test "$minos" = "12.0"
done

.venv/bin/python -m unittest tests.test_open_source_policy -v
git diff --check
git status --short
```

Expected: both executables report `minos 12.0`, open-source policy passes, diff check is clean, and only the intended documentation files remain uncommitted.

- [ ] **Step 7: Commit the policy alignment**

Run:

```bash
git add \
  docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md \
  docs/superpowers/plans/2026-07-17-self-contained-onboarding.md
git diff --cached --check
git commit -m "docs: align onboarding with fresh enrollment"
```

Expected: one documentation commit.

- [ ] **Step 8: Prepare the task review package**

Before Task 1, record the implementation base:

```bash
git rev-parse HEAD > .superpowers/sdd/defer-migration-base.txt
```

After both commits, run:

```bash
BASE_COMMIT="$(cat .superpowers/sdd/defer-migration-base.txt)"
/Users/wuyi-macs/.codex/plugins/cache/openai-curated-remote/superpowers/6.1.1/skills/subagent-driven-development/scripts/review-package "$BASE_COMMIT" HEAD
```

The reviewer must verify:

- no automatic migration runtime, UI, CI target, or test remains;
- old source-beta data is never scanned or modified;
- preparation advances without a migration choice;
- enrollment remains mandatory for a fresh release profile;
- the static notice matches the approved text exactly;
- Task 8 readiness and service-repair behavior remains intact;
- Task 10 has not started.
