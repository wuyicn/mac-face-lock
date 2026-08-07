# Mac Face Lock Release Readiness Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the verified local release blockers without publishing, mutating macOS privacy permissions, or touching the dirty main checkout.

**Architecture:** Keep the existing dual-platform CI shape, but make macOS-only icon behavior self-identifying at test load time. Extend the release manifest from schema v2 to v3 with an explicit Git commit identity captured only from a clean tracked worktree, then surface that identity through manual acceptance. Keep public documentation guarded by policy tests so repository and Release claims remain truthful.

**Tech Stack:** Python 3.11 `unittest`, Swift/macOS command-line tools, Bash, GitHub Actions YAML, JSON release manifests, Markdown.

## Global Constraints

- Work only in `.worktrees/codex-self-contained-onboarding` on branch `codex/self-contained-onboarding`.
- Do not modify the main checkout's untracked files.
- Preserve Apple Silicon and macOS 12.0 as the release baseline.
- Preserve unified TCC identity `com.wuyi.mac-face-lock.app`.
- Do not push, merge, publish a GitHub Release, change branch protection, install the app, restart services, change TCC permissions, or enable protection.
- Every behavior change must follow RED, GREEN, and focused regression verification.

---

### Task 1: Isolate macOS icon tests from Linux CI

**Files:**
- Modify: `tests/test_open_source_policy.py`
- Modify: `tests/test_packaging.py`

**Interfaces:**
- Consumes: Python `sys.platform`, `shutil.which`, and the existing `UnifiedPackagingTests` test names.
- Produces: module constant `MACOS_ICON_TOOLCHAIN_AVAILABLE: bool` and skip metadata on `test_control_center_packages_the_project_owned_icon` and `test_app_icon_regeneration_uses_fixed_pixels_and_matches_asset`.

- [ ] **Step 1: Write the failing Linux-simulation regression test**

Add `test_macos_icon_tests_are_skipped_when_imported_as_linux` to `OpenSourcePolicyTests`. It must run a fresh Python interpreter that sets `sys.platform = "linux"`, imports `tests.test_packaging`, and exits nonzero unless both named test methods have `__unittest_skip__ is True`.

```python
probe = """
import sys
sys.platform = "linux"
from tests.test_packaging import UnifiedPackagingTests
names = (
    "test_control_center_packages_the_project_owned_icon",
    "test_app_icon_regeneration_uses_fixed_pixels_and_matches_asset",
)
raise SystemExit(0 if all(
    getattr(getattr(UnifiedPackagingTests, name), "__unittest_skip__", False)
    for name in names
) else 1)
"""
result = subprocess.run(
    [sys.executable, "-c", probe],
    cwd=PROJECT_DIR,
    capture_output=True,
    text=True,
)
self.assertEqual(result.returncode, 0, result.stderr)
```

- [ ] **Step 2: Run the regression test and verify RED**

Run: `.venv/bin/python -m unittest tests.test_open_source_policy.OpenSourcePolicyTests.test_macos_icon_tests_are_skipped_when_imported_as_linux -v`

Expected: FAIL because neither test currently carries unittest skip metadata.

- [ ] **Step 3: Add the minimal platform/toolchain guard**

In `tests/test_packaging.py`, define:

```python
MACOS_ICON_TOOLCHAIN_AVAILABLE = (
    sys.platform == "darwin"
    and shutil.which("xcrun") is not None
    and shutil.which("iconutil") is not None
)
```

Decorate both icon tests with:

```python
@unittest.skipUnless(
    MACOS_ICON_TOOLCHAIN_AVAILABLE,
    "requires macOS xcrun and iconutil",
)
```

- [ ] **Step 4: Run focused GREEN and local macOS icon tests**

Run: `.venv/bin/python -m unittest tests.test_open_source_policy.OpenSourcePolicyTests.test_macos_icon_tests_are_skipped_when_imported_as_linux tests.test_packaging.UnifiedPackagingTests.test_control_center_packages_the_project_owned_icon tests.test_packaging.UnifiedPackagingTests.test_app_icon_regeneration_uses_fixed_pixels_and_matches_asset -v`

Expected: 3 tests pass on this Mac; the subprocess proves both methods skip on Linux.

- [ ] **Step 5: Commit the CI repair**

```bash
git add tests/test_open_source_policy.py tests/test_packaging.py
git commit -m "fix: isolate macOS icon tests from Linux CI"
```

---

### Task 2: Make public release and security documentation truthful

**Files:**
- Modify: `tests/test_open_source_policy.py`
- Modify: `README.md`
- Modify: `SECURITY.md`

**Interfaces:**
- Consumes: GitHub repository URL `https://github.com/wuyicn/mac-face-lock` and its enabled private vulnerability reporting state.
- Produces: durable documentation semantics: official Releases are the only customer channel; an empty Releases page means no public customer build; private vulnerabilities use GitHub Security Advisories.

- [ ] **Step 1: Replace the stale policy test with failing current-state assertions**

Replace `test_security_policy_does_not_claim_an_unverified_private_channel` with `test_security_policy_publishes_the_verified_private_channel`, asserting all of:

```python
self.assertIn("仓库已经公开", security)
self.assertIn("private vulnerability reporting 已启用", security)
self.assertIn("GitHub Security Advisories", security)
self.assertIn("Report a vulnerability", security)
self.assertNotIn("尚未创建公开 GitHub 仓库", security)
self.assertNotIn("尚未启用", security)
```

Extend `test_customer_release_documentation_is_complete` to require `如果 Releases 页面没有发行版` and `尚未公开客户构建`.

- [ ] **Step 2: Run the two policy tests and verify RED**

Run: `.venv/bin/python -m unittest tests.test_open_source_policy.OpenSourcePolicyTests.test_security_policy_publishes_the_verified_private_channel tests.test_open_source_policy.OpenSourcePolicyTests.test_customer_release_documentation_is_complete -v`

Expected: FAIL on the stale SECURITY and unconditional download copy.

- [ ] **Step 3: Update README and SECURITY with permanent-state wording**

Update README's customer download paragraph to say customers may download only from the official Releases page, and if it has no release then no customer build has been published. Update SECURITY to state the public repository and enabled private vulnerability reporting, direct reporters to **Report a vulnerability**, and keep the existing warning not to disclose private artifacts in public issues or PRs.

- [ ] **Step 4: Run focused GREEN and all open-source policy tests**

Run: `.venv/bin/python -m unittest tests.test_open_source_policy -v`

Expected: all policy tests pass.

- [ ] **Step 5: Commit the documentation repair**

```bash
git add README.md SECURITY.md tests/test_open_source_policy.py
git commit -m "docs: align release and security guidance"
```

---

### Task 3: Embed a clean Git commit identity in release manifests

**Files:**
- Modify: `tests/test_release_bundle.py`
- Modify: `scripts/release-manifest.py`
- Modify: `scripts/build-release.sh`
- Modify: `scripts/manual-release-acceptance.sh`

**Interfaces:**
- Consumes: exact 40-character lowercase hexadecimal Git `HEAD` SHA and a worktree with no tracked or untracked non-ignored changes.
- Produces: `BuildManifest.json` schema v3 with `source_commit: str`; command `release-manifest.py generate APP MANIFEST SOURCE_COMMIT`; verification continues as `release-manifest.py verify APP MANIFEST`.

- [ ] **Step 1: Write failing schema v3 and SHA validation tests**

Update `ReleaseManifestToolTests` so its fixture uses a constant SHA such as `0123456789abcdef0123456789abcdef01234567` and calls generate with that fourth operand. Assert schema version 3 and exact `source_commit`. Add focused tests proving generate rejects uppercase/short/non-hex SHAs and verify rejects a manifest whose `source_commit` is changed to another value that is not a valid 40-character lowercase hexadecimal SHA.

Add policy assertions that `build-release.sh` uses `git status --porcelain=v1 --untracked-files=all`, `git rev-parse HEAD`, and passes `"$SOURCE_COMMIT"` to manifest generation. Add an assertion that `manual-release-acceptance.sh` prints `source_commit` from the manifest.

- [ ] **Step 2: Run manifest and release policy tests and verify RED**

Run: `.venv/bin/python -m unittest tests.test_release_bundle.ReleaseManifestToolTests tests.test_release_bundle.ReleaseBundlePolicyTests -v`

Expected: FAIL because schema v2 has no source commit and generate accepts only three operands.

- [ ] **Step 3: Implement schema v3 and strict commit validation**

In `release-manifest.py`:

```python
SOURCE_COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
```

Add `source_commit` to `MANIFEST_KEYS`; require `SOURCE_COMMIT_PATTERN.fullmatch` during generate and verify; generate schema version 3; update CLI parsing so generate requires `APP MANIFEST SOURCE_COMMIT` while verify still requires `APP MANIFEST`.

- [ ] **Step 4: Make release build fail closed on dirty Git state**

Near the start of `build-release.sh`, require `git -C "$ROOT_DIR" rev-parse --is-inside-work-tree` to equal `true`, collect `git status --porcelain=v1 --untracked-files=all`, fail with a concise message if nonempty, set `SOURCE_COMMIT` from `git -C "$ROOT_DIR" rev-parse HEAD`, and validate it against `^[0-9a-f]{40}$`. Pass it as the final generate argument.

In `manual-release-acceptance.sh`, after manifest verification, read `source_commit` with Python and print `源提交：<sha>` alongside ZIP SHA-256 and version.

- [ ] **Step 5: Run focused GREEN and full release bundle tests without artifact gate**

Run: `.venv/bin/python -m unittest tests.test_release_bundle -v`

Expected: policy and manifest tests pass; extracted artifact class remains skipped because a new artifact has not yet been requested.

- [ ] **Step 6: Commit the provenance repair**

```bash
git add scripts/release-manifest.py scripts/build-release.sh scripts/manual-release-acceptance.sh tests/test_release_bundle.py
git commit -m "build: trace release artifacts to source commits"
```

---

### Task 4: Clean diff hygiene and run complete release verification

**Files:**
- Modify: `docs/superpowers/plans/2026-07-17-self-contained-onboarding.md`
- Modify: `docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md`
- Modify: `docs/superpowers/plans/2026-08-07-release-readiness-repair.md`

**Interfaces:**
- Consumes: completed Tasks 1-3 and their commits.
- Produces: a clean diff, complete local test evidence, and a newly built schema v3 ZIP tied to the final clean commit.

- [ ] **Step 1: Remove only the known trailing spaces**

Remove the two trailing spaces from the 10 command lines in the July 17 plan and the date line in the July 17 design. Do not reflow or rewrite their content.

- [ ] **Step 2: Verify diff hygiene and commit**

Run: `git diff --check && git diff --check origin/main`

Expected: no output and exit 0.

```bash
git add docs/superpowers/plans/2026-07-17-self-contained-onboarding.md docs/superpowers/specs/2026-07-17-self-contained-onboarding-design.md docs/superpowers/plans/2026-08-07-release-readiness-repair.md
git commit -m "chore: clean release branch diff hygiene"
```

Then run: `git diff --check origin/main...HEAD`

Expected: no output and exit 0 for the committed branch difference.

- [ ] **Step 3: Run the complete Python suite**

Run: `.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v`

Expected: all effective tests pass; only the documented release artifact gate may skip before the build.

- [ ] **Step 4: Run all 15 Swift suites and full typecheck**

Run the exact commands in `.github/workflows/ci.yml` for LocalStore, SetupState, PermissionState, RuntimeCommandRunner, ServiceManager, SetupCoordinator, ProjectLocator, AppEnvironment, ApplicationLaunchMode, ApplicationQuitCoordinator, AgentLauncherPath, UIEventTraceRecorder, LocalMouseEventMonitor, SecureFileTree, LegacyInstallCleaner, followed by the full `src/app/*.swift` typecheck.

Expected: all executables exit 0; the pre-existing macOS 14 `onChange` deprecation warning may remain.

- [ ] **Step 5: Run static and dependency gates**

```bash
bash -n scripts/*.sh scripts/*.command
plutil -lint src/app/Info.plist launchd/*.plist
git diff --check origin/main...HEAD
uvx --from pip-audit pip-audit -r requirements-lock.txt --progress-spinner off
```

Expected: all exit 0 and dependency audit reports no known vulnerabilities.

- [ ] **Step 6: Build and verify the final release artifact from a clean commit**

Run: `scripts/build-release.sh`

Expected: schema v3 manifest, embedded `source_commit` equal to `git rev-parse HEAD`, valid signatures, extracted release tests pass, ZIP checksum verifies, and the build does not install or start the app.

- [ ] **Step 7: Re-run the full artifact gate and record evidence**

Run: `MAC_FACE_LOCK_REQUIRE_RELEASE_ARTIFACT=1 .venv/bin/python -m unittest tests.test_release_bundle.ExtractedReleaseBundleTests -v`

Expected: all extracted release tests pass with no skip.

- [ ] **Step 8: Final state inspection**

Run: `git status --short --branch`, `git log --oneline --decorate -8`, `gh pr checks 2 --repo wuyicn/mac-face-lock`, and read-only inspection of live `state.json` plus `control.json`.

Expected: implementation worktree clean; remote PR remains unchanged until a separately authorized push; live TCC and protection are reported exactly as observed.
