# Mac Face Lock Open-Source Beta Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert Mac Face Lock into a portable, privacy-safe MIT-licensed source Beta that another Apple Silicon macOS user can clone, build, install, and test from an arbitrary directory.

**Architecture:** Keep the existing Python security Agent and unified Swift menu-bar/desktop UI, but remove every developer-machine path from committed runtime files. A Python plist renderer will generate user-specific LaunchAgents at install time, a small Swift Agent launcher will resolve the repository and virtual-environment Python dynamically, and a tested project locator will make the UI fail clearly when its project argument is missing or invalid.

**Tech Stack:** Python 3.11, `unittest`, `plistlib`, Bash, Swift/AppKit/SwiftUI, launchd, GitHub Actions, MIT License.

## Global Constraints

- Release scope is source-only `v0.1.0-beta`; do not publish prebuilt `.app`, DMG, or PKG artifacts.
- Supported platform is Apple Silicon macOS 12 or newer.
- Use MIT License with `Copyright (c) 2026 WUYI`.
- Camera failures remain fail-open: `lock_on_camera_error=false`.
- Lock and camera-error cooldowns remain at least 300 seconds.
- External notifications are disabled by default and require an explicit executable script path.
- No committed source, configuration, templates, or public documentation may contain a developer-specific home-directory absolute path.
- No CI task may access a camera, trigger a real lock, install a LaunchAgent, or require an Apple Developer certificate.

---

### Task 1: Portable LaunchAgent rendering

**Files:**
- Create: `scripts/render-launchagents.py`
- Create: `tests/test_launchagent_renderer.py`
- Modify: `launchd/com.wuyi.mac-face-lock-agent.plist`
- Modify: `launchd/com.wuyi.mac-face-lock-status.plist`
- Modify: `scripts/install-launchagent.sh`
- Modify: `tests/test_launchagent_scripts.py`
- Modify: `tests/test_packaging.py`

**Interfaces:**
- Consumes: repository root from `Path(__file__).resolve().parent.parent` or `--project-dir`.
- Produces: `render_launchagents(project_dir: Path, output_dir: Path) -> tuple[Path, Path]` and two valid generated plist files.

- [ ] **Step 1: Write failing renderer tests**

Add tests that render from a temporary root containing spaces, Chinese characters, and XML-sensitive characters, then load both outputs using `plistlib`:

```python
class LaunchAgentRendererTests(unittest.TestCase):
    def test_renders_arbitrary_project_path_without_template_tokens(self):
        with tempfile.TemporaryDirectory(prefix="Mac 人脸 & Lock ") as directory:
            root = Path(directory)
            output = root / "generated"
            agent_path, ui_path = render_launchagents(root, output)
            agent = plistlib.loads(agent_path.read_bytes())
            ui = plistlib.loads(ui_path.read_bytes())
            self.assertEqual(agent["WorkingDirectory"], str(root))
            self.assertEqual(ui["WorkingDirectory"], str(root))
            self.assertEqual(agent["ProgramArguments"][1], str(root))
            self.assertEqual(ui["ProgramArguments"][1], str(root))
            self.assertNotIn("__PROJECT_DIR__", agent_path.read_text())
            self.assertNotIn("__PROJECT_DIR__", ui_path.read_text())

    def test_generated_agent_uses_built_launcher_without_pythonpath(self):
        root = Path("/tmp/Mac Face Lock").resolve()
        with tempfile.TemporaryDirectory() as directory:
            agent_path, _ = render_launchagents(root, Path(directory))
            agent = plistlib.loads(agent_path.read_bytes())
            self.assertEqual(
                agent["ProgramArguments"][0],
                str(root / "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"),
            )
            self.assertNotIn("PYTHONPATH", agent.get("EnvironmentVariables", {}))
```

- [ ] **Step 2: Run the renderer test to verify RED**

Run: `.venv/bin/python -m unittest tests.test_launchagent_renderer -v`
Expected: FAIL because `scripts/render-launchagents.py` and `render_launchagents` do not exist.

- [ ] **Step 3: Implement the renderer and generic templates**

Implement `scripts/render-launchagents.py` with `plistlib` rather than string replacement:

```python
AGENT_LABEL = "com.wuyi.mac-face-lock-agent"
UI_LABEL = "com.wuyi.mac-face-lock-status"

def render_launchagents(project_dir: Path, output_dir: Path) -> tuple[Path, Path]:
    root = project_dir.expanduser().resolve(strict=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    values = {
        AGENT_LABEL: {
            "program": root / "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent",
            "arguments": [str(root)],
            "stdout": root / "logs/agent.out.log",
            "stderr": root / "logs/agent.err.log",
        },
        UI_LABEL: {
            "program": root / "dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock",
            "arguments": [str(root)],
            "stdout": root / "logs/status.out.log",
            "stderr": root / "logs/status.err.log",
        },
    }
```

Load each committed plist template, replace `ProgramArguments`, `WorkingDirectory`, `StandardOutPath`, and `StandardErrorPath`, remove `PYTHONPATH`, and write XML plists atomically. Add a CLI accepting `--project-dir` and `--output-dir` and printing the two output paths.

Replace all committed absolute paths in both templates with `__PROJECT_DIR__` tokens so templates remain readable and `plutil`-parseable.

- [ ] **Step 4: Update installer worktree detection and generated-plist use**

Remove `EXPECTED_ROOT`. Add a read-only linked-worktree guard:

```bash
GIT_DIR="$(cd "$(git rev-parse --git-dir)" && pwd -P)"
GIT_COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
if [[ "$GIT_DIR" != "$GIT_COMMON" && "${MAC_FACE_LOCK_TEST_MODE:-0}" != "1" ]]; then
  echo "为避免安装临时工作树产物，请在主仓库目录运行安装脚本" >&2
  exit 1
fi
```

Create `BACKUP_DIR` before rendering, invoke `.venv/bin/python scripts/render-launchagents.py`, lint both generated plists, and copy generated files to `~/Library/LaunchAgents` only after all build and validation gates pass.

- [ ] **Step 5: Update existing installer and packaging tests**

Replace assertions for the fixed root with assertions that:

```python
self.assertNotIn("/" + "Users" + "/", INSTALL_SCRIPT.read_text())
self.assertIn("render-launchagents.py", INSTALL_SCRIPT.read_text())
self.assertIn("git rev-parse --git-common-dir", INSTALL_SCRIPT.read_text())
```

Retain the existing fake-`launchctl` rollback, stable-PID, wrong-program, and linked-worktree tests.

- [ ] **Step 6: Verify Task 1 GREEN**

Run:

```bash
.venv/bin/python -m unittest \
  tests.test_launchagent_renderer \
  tests.test_launchagent_scripts \
  tests.test_packaging -v
```

Expected: all renderer, installer transaction, worktree guard, and packaging tests pass.

- [ ] **Step 7: Commit Task 1**

```bash
git add scripts/render-launchagents.py tests/test_launchagent_renderer.py \
  launchd/*.plist scripts/install-launchagent.sh \
  tests/test_launchagent_scripts.py tests/test_packaging.py
git commit -m "feat: render portable launch agents"
```

---

### Task 2: Portable Agent application launcher

**Files:**
- Create: `src/agent-launcher/main.swift`
- Create: `tests/swift/AgentLauncherPathTests.swift`
- Modify: `scripts/build-app.sh`
- Modify: `tests/test_packaging.py`

**Interfaces:**
- Consumes: `MacFaceLockAgent <absolute-project-directory>`.
- Produces: an Agent bundle executable that runs `<project>/.venv/bin/python -u <project>/agent.py` using `execv`.

- [ ] **Step 1: Write failing packaging assertions**

Add tests:

```python
def test_agent_builder_compiles_portable_launcher(self):
    script = (PROJECT_DIR / "scripts/build-app.sh").read_text()
    self.assertIn("src/agent-launcher/main.swift", script)
    self.assertNotIn("CommandLineTools/Library/Frameworks/Python3.framework", script)
    self.assertNotIn("install_name_tool", script)

def test_agent_launcher_has_no_developer_path(self):
    source = (PROJECT_DIR / "src/agent-launcher/main.swift").read_text()
    self.assertNotIn("/" + "Users" + "/", source)
```

- [ ] **Step 2: Run packaging test to verify RED**

Run: `.venv/bin/python -m unittest tests.test_packaging.UnifiedPackagingTests.test_agent_builder_compiles_portable_launcher -v`
Expected: FAIL because the existing builder copies Command Line Tools Python.

- [ ] **Step 3: Implement launcher path validation**

Create a small Swift launcher with a testable function:

```swift
enum AgentLaunchError: Error, Equatable {
    case missingProjectArgument
    case invalidProjectDirectory(String)
    case missingVirtualEnvironment(String)
    case missingAgent(String)
}

func resolveAgentLaunch(arguments: [String]) throws -> (python: String, agent: String) {
    guard arguments.count == 2 else { throw AgentLaunchError.missingProjectArgument }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
    let python = root.appendingPathComponent(".venv/bin/python").path
    let agent = root.appendingPathComponent("agent.py").path
    guard FileManager.default.isExecutableFile(atPath: python) else {
        throw AgentLaunchError.missingVirtualEnvironment(python)
    }
    guard FileManager.default.fileExists(atPath: agent) else {
        throw AgentLaunchError.missingAgent(agent)
    }
    return (python, agent)
}
```

The executable prints a concise error to standard error and exits `64` for invalid arguments or `78` for missing local setup. On success, call `execv` with `[python, "-u", agent]`.

- [ ] **Step 4: Add Swift path tests and verify RED/GREEN**

Test missing arguments, missing `.venv/bin/python`, and a valid temporary project. Compile with:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/agent-launcher/main.swift tests/swift/AgentLauncherPathTests.swift \
  -o /tmp/mac-face-lock-agent-launcher-tests
/tmp/mac-face-lock-agent-launcher-tests
```

Expected after implementation: `Agent launcher path tests passed`.

- [ ] **Step 5: Replace copied Python with compiled launcher**

Update `scripts/build-app.sh` to compile `src/agent-launcher/main.swift` directly into the bundle executable, preserve camera usage descriptions, use ad-hoc signing, and remove `PYTHON_SOURCE`, `PYTHON_DYLIB`, `cp`, and `install_name_tool` logic.

- [ ] **Step 6: Verify Agent bundle**

Run:

```bash
.venv/bin/python -m unittest tests.test_packaging -v
scripts/build-app.sh
codesign --verify --deep --strict "dist/Mac Face Lock Agent.app"
file "dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent"
```

Expected: tests pass, signature verifies, and executable architecture matches the build Mac.

- [ ] **Step 7: Commit Task 2**

```bash
git add src/agent-launcher/main.swift tests/swift/AgentLauncherPathTests.swift \
  scripts/build-app.sh tests/test_packaging.py
git commit -m "feat: add portable agent launcher"
```

---

### Task 3: Explicit Swift project location

**Files:**
- Create: `src/app/ProjectLocator.swift`
- Create: `tests/swift/ProjectLocatorTests.swift`
- Modify: `src/app/AppDelegate.swift`
- Modify: `src/app/Views.swift`
- Modify: `scripts/build-status-app.sh`
- Modify: `tests/test_packaging.py`

**Interfaces:**
- Produces: `ProjectLocator.locate(arguments: [String]) throws -> URL`.
- Consumes: exactly one absolute project path argument containing `config/config.json` and `data/` or a creatable project-owned data directory.

- [ ] **Step 1: Write failing Swift locator tests**

Test:

```swift
expectError(.missingProjectArgument) {
    try ProjectLocator.locate(arguments: ["MacFaceLock"])
}
expectError(.relativeProjectPath("relative")) {
    try ProjectLocator.locate(arguments: ["MacFaceLock", "relative"])
}
let located = try ProjectLocator.locate(arguments: ["MacFaceLock", validRoot.path])
precondition(located.standardizedFileURL == validRoot.standardizedFileURL)
```

- [ ] **Step 2: Run locator test to verify RED**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift tests/swift/ProjectLocatorTests.swift \
  -o /tmp/mac-face-lock-project-locator-tests
```

Expected: FAIL because `ProjectLocator.swift` does not exist.

- [ ] **Step 3: Implement ProjectLocator and UI error flow**

Implement absolute-path, directory, and `config/config.json` validation. `AppDelegate` stores `Result<URL, ProjectLocatorError>` during initialization. On failure, log the localized message, present one `NSAlert` titled `Mac Face Lock 无法启动`, and terminate without creating `LocalJSONStore`.

Remove both hard-coded fallback paths from `AppDelegate.swift` and `Views.swift`. Pass the validated `projectURL` into `WorkspaceLinks` actions instead of reading `CommandLine.arguments` again.

- [ ] **Step 4: Update build and tests**

Ensure `src/app/*.swift` includes the locator automatically. Extend packaging policy checks:

```python
for source in (PROJECT_DIR / "src/app").glob("*.swift"):
    self.assertNotIn("/" + "Users" + "/", source.read_text())
```

- [ ] **Step 5: Verify Task 3 GREEN**

Run:

```bash
xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift tests/swift/ProjectLocatorTests.swift \
  -o /tmp/mac-face-lock-project-locator-tests
/tmp/mac-face-lock-project-locator-tests
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI
.venv/bin/python -m unittest tests.test_packaging -v
```

Expected: locator tests, Swift typecheck, and packaging tests pass.

- [ ] **Step 6: Commit Task 3**

```bash
git add src/app/ProjectLocator.swift tests/swift/ProjectLocatorTests.swift \
  src/app/AppDelegate.swift src/app/Views.swift \
  scripts/build-status-app.sh tests/test_packaging.py
git commit -m "fix: require an explicit project location"
```

---

### Task 4: Privacy-safe optional notifications

**Files:**
- Create: `tests/test_event_notifier.py`
- Modify: `event_notifier.py`
- Modify: `config/config.json`
- Modify: `tests/test_config.py`
- Modify: `tests/test_agent_control.py`

**Interfaces:**
- `notify_lock_event(config, reason, evidence_path) -> dict | None` returns `None` when disabled.
- When enabled, `event_notify_script` must be a non-empty executable file path.

- [ ] **Step 1: Write failing default and validation tests**

```python
def test_default_config_disables_external_notifications(self):
    config = json.loads(CONFIG_PATH.read_text())
    self.assertIs(config["event_notify_on_lock"], False)
    self.assertEqual(config["event_notify_script"], "")

def test_enabled_notification_requires_configured_script(self):
    with self.assertRaisesRegex(ValueError, "event_notify_script"):
        notify_lock_event({"event_notify_on_lock": True, "event_notify_script": ""}, "stranger", None)

def test_disabled_notification_never_runs_subprocess(self):
    with mock.patch("event_notifier.subprocess.run") as run:
        result = notify_lock_event({"event_notify_on_lock": False}, "stranger", None)
    self.assertIsNone(result)
    run.assert_not_called()
```

- [ ] **Step 2: Run tests to verify RED**

Run: `.venv/bin/python -m unittest tests.test_event_notifier tests.test_config -v`
Expected: FAIL because current defaults enable a developer-specific notification script.

- [ ] **Step 3: Implement explicit notification configuration**

Set `event_notify_on_lock` to `false` and `event_notify_script` to `""`. Remove `DEFAULT_EVENT_SCRIPT`. Validate with:

```python
def _event_script(config: dict[str, Any]) -> str:
    value = str(config.get("event_notify_script", "")).strip()
    if not value:
        raise ValueError("event_notify_script is required when lock notifications are enabled")
    path = Path(value).expanduser()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError(f"event_notify_script is not executable: {path}")
    return str(path.resolve())
```

Preserve the existing argument protocol, timeout handling, media attachment, and dedupe key.

- [ ] **Step 4: Adjust Agent tests for opt-in behavior**

Fixtures that assert notification queuing must explicitly set `event_notify_on_lock=True` and provide an executable temporary script or patch `_run_add_event`. Fixtures testing ordinary locks must inherit the disabled default.

- [ ] **Step 5: Verify Task 4 GREEN**

Run:

```bash
.venv/bin/python -m unittest \
  tests.test_event_notifier tests.test_config tests.test_agent_control -v
```

Expected: all notification, configuration, and Agent concurrency tests pass.

- [ ] **Step 6: Commit Task 4**

```bash
git add tests/test_event_notifier.py event_notifier.py config/config.json \
  tests/test_config.py tests/test_agent_control.py
git commit -m "fix: make external notifications opt in"
```

---

### Task 5: Open-source repository policy and reproducible dependencies

**Files:**
- Create: `tests/test_open_source_policy.py`
- Create: `requirements-lock.txt`
- Modify: `requirements.txt`
- Modify: `.gitignore`
- Modify: `scripts/bootstrap.sh`
- Delete: `.superpowers/sdd/task-9-report.md`

**Interfaces:**
- Produces: one repository policy test suite used locally and in CI.

- [ ] **Step 1: Write failing repository policy tests**

```python
PUBLIC_SUFFIXES = {".py", ".swift", ".sh", ".command", ".plist", ".json", ".md", ".yml", ".yaml"}

def test_public_files_have_no_developer_absolute_path(self):
    offenders = []
    for path in tracked_files():
        if path.suffix.lower() in PUBLIC_SUFFIXES:
            text = path.read_text(encoding="utf-8", errors="ignore")
            if "/" + "Users" + "/" in text:
                offenders.append(str(path.relative_to(PROJECT_DIR)))
    self.assertEqual(offenders, [])

def test_private_runtime_paths_are_ignored(self):
    ignored = subprocess.run(
        ["git", "check-ignore", "data/owner_face.npy", "data/state.json", "data/evidence/example.jpg", "logs/agent.log", ".venv/bin/python", "dist/example"],
        cwd=PROJECT_DIR, text=True, capture_output=True, check=True,
    ).stdout.splitlines()
    self.assertEqual(len(ignored), 6)

def test_requirements_are_exactly_pinned(self):
    for line in REQUIREMENTS.read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            self.assertRegex(line, r"^[A-Za-z0-9_.-]+==[^=<>~!]+$")
```

- [ ] **Step 2: Run policy tests to verify RED**

Run: `.venv/bin/python -m unittest tests.test_open_source_policy -v`
Expected: FAIL on developer paths and non-exact dependency constraints.

- [ ] **Step 3: Pin dependencies and clean tracked internal material**

Set:

```text
numpy==2.0.2
opencv-python==4.13.0.92
pynput==1.8.1
```

Keep all existing privacy ignores, add generated plist staging patterns if required, and remove `.superpowers/sdd/task-9-report.md` from version control.

- [ ] **Step 4: Remove remaining developer paths**

Replace examples in README, session handoff, plans, tests, config, templates, and source with `$PROJECT_DIR`, `/path/to/mac-face-lock-agent`, or dynamically computed paths. Product runtime files may retain bundle identifiers containing `wuyi`; the policy test targets filesystem paths, not reverse-DNS identifiers.

- [ ] **Step 5: Verify Task 5 GREEN**

Run:

```bash
.venv/bin/python -m unittest tests.test_open_source_policy -v
.venv/bin/python -m pip install -r requirements-lock.txt
.venv/bin/python -m compileall -q -x '/\.git/|/\.venv/|/dist/' .
```

Expected: policy tests pass, pinned dependencies install, and Python compilation succeeds.

- [ ] **Step 6: Commit Task 5**

```bash
git add tests/test_open_source_policy.py requirements.txt requirements-lock.txt \
  .gitignore scripts/bootstrap.sh \
  README.md docs config launchd scripts src tests event_notifier.py
git rm .superpowers/sdd/task-9-report.md
git commit -m "chore: enforce public repository policy"
```

---

### Task 6: MIT license and public project documentation

**Files:**
- Create: `LICENSE`
- Create: `SECURITY.md`
- Create: `CONTRIBUTING.md`
- Create: `CHANGELOG.md`
- Create: `THIRD_PARTY_NOTICES.md`
- Modify: `README.md`
- Modify: `src/app/Info.plist`
- Modify: `scripts/build-app.sh`
- Modify: `tests/test_open_source_policy.py`
- Modify: `tests/test_packaging.py`

**Interfaces:**
- Produces: public project contract for version `0.1.0-beta` and machine-checkable documentation requirements.

- [ ] **Step 1: Write failing documentation checks**

```python
def test_required_open_source_documents_exist(self):
    for name in ["LICENSE", "SECURITY.md", "CONTRIBUTING.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md"]:
        self.assertTrue((PROJECT_DIR / name).is_file(), name)

def test_readme_states_beta_and_security_limits(self):
    readme = (PROJECT_DIR / "README.md").read_text()
    for phrase in ["源码 Beta", "没有活体检测", "不能替代", "通知默认关闭", "MIT"]:
        self.assertIn(phrase, readme)
```

Update packaging tests to expect `CFBundleShortVersionString` and `CFBundleVersion` to represent `0.1.0` consistently in both apps.

- [ ] **Step 2: Run documentation tests to verify RED**

Run: `.venv/bin/python -m unittest tests.test_open_source_policy tests.test_packaging -v`
Expected: FAIL because public community documents and aligned Beta version metadata do not exist.

- [ ] **Step 3: Add exact MIT text and third-party notices**

Use the standard MIT license text with:

```text
Copyright (c) 2026 WUYI
```

List NumPy, OpenCV Python, and pynput with installed versions, upstream repository URLs, and BSD/Apache-2.0/LGPLv3 identifiers. State that dependencies are installed separately through pip and remain governed by their own licenses.

- [ ] **Step 4: Write security and contribution contracts**

`SECURITY.md` must cover supported version `0.1.x Beta`, private reporting through GitHub Security Advisories, camera fail-open behavior, absence of liveness detection, and excluded high-security use cases.

`CONTRIBUTING.md` must require tests, prohibit real face templates/evidence/logs, describe the full verification command, and require contributors to preserve privacy-safe defaults.

`CHANGELOG.md` must use a Keep a Changelog structure and document the portable installer, unified UI, fail-open policy, local data, and source-only status under `[0.1.0-beta] - 2026-07-15`.

- [ ] **Step 5: Rewrite README for public users and align versions**

Keep the product workflow and UI description, but replace the developer-specific project location with:

```bash
git clone <repository-url>
cd mac-face-lock-agent
scripts/bootstrap.sh
scripts/enroll-owner.sh
scripts/install-launchagent.sh
```

Use `<repository-url>` only in the clone example until the actual GitHub remote exists. Clearly state source-only Beta, Apple Silicon/macOS 12+, permission requirements, default offline behavior, optional notification interface, uninstall data preservation, lack of liveness detection, and full test commands.

Set both bundle marketing versions to `0.1.0` and build versions to `1`; describe the Git tag separately as `v0.1.0-beta`.

- [ ] **Step 6: Verify Task 6 GREEN**

Run:

```bash
.venv/bin/python -m unittest tests.test_open_source_policy tests.test_packaging -v
plutil -lint src/app/Info.plist
scripts/build-app.sh
scripts/build-status-app.sh
```

Expected: documentation and packaging checks pass and both Beta-version bundles build.

- [ ] **Step 7: Commit Task 6**

```bash
git add LICENSE SECURITY.md CONTRIBUTING.md CHANGELOG.md \
  THIRD_PARTY_NOTICES.md README.md src/app/Info.plist \
  scripts/build-app.sh tests/test_open_source_policy.py tests/test_packaging.py
git commit -m "docs: prepare MIT source beta"
```

---

### Task 7: GitHub Actions continuous integration

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `tests/test_open_source_policy.py`

**Interfaces:**
- Produces: Linux policy/Python job and macOS Swift/build job for pushes and pull requests.

- [ ] **Step 1: Write failing CI policy test**

```python
def test_ci_runs_python_and_macos_release_gates(self):
    workflow = (PROJECT_DIR / ".github/workflows/ci.yml").read_text()
    for phrase in ["pull_request:", "ubuntu-latest", "macos-14", "pip install -r requirements-lock.txt", "unittest discover", "swiftc", "build-app.sh", "build-status-app.sh"]:
        self.assertIn(phrase, workflow)
    for forbidden in ["install-launchagent.sh", "camera-diagnostic.sh", "lock-now.sh"]:
        self.assertNotIn(forbidden, workflow)
    self.assertNotIn("pip install -r requirements.txt", workflow)
```

- [ ] **Step 2: Run CI policy test to verify RED**

Run: `.venv/bin/python -m unittest tests.test_open_source_policy.OpenSourcePolicyTests.test_ci_runs_python_and_macos_release_gates -v`
Expected: FAIL because `.github/workflows/ci.yml` does not exist.

- [ ] **Step 3: Add Linux and macOS CI jobs**

Linux job:

```yaml
- uses: actions/checkout@v4
- uses: actions/setup-python@v5
  with:
    python-version: "3.11"
- run: python -m pip install -r requirements-lock.txt
- run: python -m unittest discover -s tests -p 'test_*.py' -v
- run: python -m compileall -q -x '/\.git/|/\.venv/|/dist/' .
- run: bash -n scripts/*.sh scripts/*.command
```

macOS job uses `macos-14` and installs dependencies with:

```yaml
- run: python -m pip install -r requirements-lock.txt
```

It then runs the same unit tests, Swift smoke/locator/launcher tests, Swift typecheck, both build scripts, plist lint, and ad-hoc signature verification. Do not install services or invoke camera/lock scripts.

- [ ] **Step 4: Verify Task 7 GREEN**

Run:

```bash
.venv/bin/python -m unittest tests.test_open_source_policy -v
.venv/bin/python -c 'import pathlib; text=pathlib.Path(".github/workflows/ci.yml").read_text(); assert "install-launchagent.sh" not in text'
```

Expected: policy tests pass and dangerous runtime commands are absent.

- [ ] **Step 5: Commit Task 7**

```bash
git add .github/workflows/ci.yml tests/test_open_source_policy.py
git commit -m "ci: add source beta verification"
```

---

### Task 8: Arbitrary-path release verification

**Files:**
- Modify only if a failing release gate exposes a defect covered by a new regression test.

**Interfaces:**
- Consumes: completed Tasks 1-7.
- Produces: evidence that the source Beta builds and renders valid services outside the developer path.

- [ ] **Step 1: Run the complete Python test suite**

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: all tests pass with zero failures or errors.

- [ ] **Step 2: Run all Swift test and typecheck gates**

```bash
xcrun swiftc -parse-as-library \
  src/app/Models.swift src/app/LocalJSONStore.swift \
  tests/swift/LocalStoreSmokeTests.swift \
  -o /tmp/mac-face-lock-store-tests
/tmp/mac-face-lock-store-tests

xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift tests/swift/ProjectLocatorTests.swift \
  -o /tmp/mac-face-lock-project-locator-tests
/tmp/mac-face-lock-project-locator-tests

xcrun swiftc -parse-as-library -DTESTING \
  src/agent-launcher/main.swift tests/swift/AgentLauncherPathTests.swift \
  -o /tmp/mac-face-lock-agent-launcher-tests
/tmp/mac-face-lock-agent-launcher-tests

xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI
```

Expected: every executable prints its pass message and typecheck exits zero.

- [ ] **Step 3: Build and verify both bundles**

```bash
scripts/build-app.sh
scripts/build-status-app.sh
plutil -lint launchd/com.wuyi.mac-face-lock-agent.plist \
  launchd/com.wuyi.mac-face-lock-status.plist
codesign --verify --deep --strict "dist/Mac Face Lock Agent.app"
codesign --verify --deep --strict "dist/Mac Face Lock.app"
```

Expected: both bundles build and verify with ad-hoc signatures.

- [ ] **Step 4: Verify rendering from an arbitrary temporary path**

Create a temporary copy whose name contains spaces and Chinese characters, create its virtual environment or link the verified local `.venv` only for the build check, run both build scripts, render LaunchAgents, and lint the generated plists. Do not run `scripts/install-launchagent.sh` in the temporary copy.

```bash
TEMP_ROOT="$(mktemp -d)/Mac 人脸保护 Beta"
mkdir -p "$TEMP_ROOT"
git archive HEAD | tar -x -C "$TEMP_ROOT"
ln -s "$PWD/.venv" "$TEMP_ROOT/.venv"
(cd "$TEMP_ROOT" && scripts/build-app.sh && scripts/build-status-app.sh)
"$TEMP_ROOT/.venv/bin/python" "$TEMP_ROOT/scripts/render-launchagents.py" \
  --project-dir "$TEMP_ROOT" --output-dir "$TEMP_ROOT/generated"
plutil -lint "$TEMP_ROOT/generated/"*.plist
rm -rf "$(dirname "$TEMP_ROOT")"
```

Expected: builds and plist lint succeed without developer paths.

- [ ] **Step 5: Run privacy, history, and repository cleanliness checks**

```bash
USER_HOME_PREFIX="/Us""ers/"
git grep -n -I "$USER_HOME_PREFIX" -- .
git ls-files | rg -i '(^|/)(data|logs|evidence)(/|$)|\.(npy|jpg|jpeg|pem|p12|mobileprovision)$' | rg -v '^docs/design-references/'
git diff --check
git status --short
```

Expected: the first two checks print nothing; diff check succeeds; only intentional implementation changes are present before the final commit.

- [ ] **Step 6: Record the release verification and commit**

Add a dated `0.1.0-beta` verification section to `docs/design-qa.md` listing commands and outcomes, without machine paths, PIDs, face images, or log excerpts.

```bash
git add docs/design-qa.md
git commit -m "docs: record source beta verification"
```

- [ ] **Step 7: Stop before public history rewrite or GitHub publication**

Report the current branch, commits, verification evidence, and remaining Git-author privacy issue. Do not rewrite commit history, add a GitHub remote, push, create a public repository, or tag `v0.1.0-beta` until the user supplies the intended public GitHub identity and explicitly authorizes publication.
