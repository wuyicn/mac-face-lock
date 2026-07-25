import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import cv2


PROJECT_DIR = Path(__file__).resolve().parents[1]
REQUIREMENTS = PROJECT_DIR / "requirements.txt"
LOCK_REQUIREMENTS = PROJECT_DIR / "requirements-lock.txt"
CI_WORKFLOW = PROJECT_DIR / ".github" / "workflows" / "ci.yml"
RELEASE_WORKFLOW = PROJECT_DIR / ".github" / "workflows" / "release-artifact.yml"
BOOTSTRAP = PROJECT_DIR / "scripts" / "bootstrap.sh"
README = PROJECT_DIR / "README.md"
THIRD_PARTY_NOTICES = PROJECT_DIR / "THIRD_PARTY_NOTICES.md"
PUBLIC_DOCUMENTS = (
    "LICENSE",
    "SECURITY.md",
    "CONTRIBUTING.md",
    "CHANGELOG.md",
    "THIRD_PARTY_NOTICES.md",
)
STANDARD_MIT_LICENSE = """MIT License

Copyright (c) 2026 WUYI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
IMPLEMENTATION_PLAN = (
    PROJECT_DIR / "docs" / "superpowers" / "plans" / "2026-07-15-open-source-beta.md"
)
DIRECT_DEPENDENCIES = {"numpy", "opencv-python", "pynput"}
MACOS_DEPENDENCIES = DIRECT_DEPENDENCIES | {
    "six",
    "pyobjc-core",
    "pyobjc-framework-applicationservices",
    "pyobjc-framework-cocoa",
    "pyobjc-framework-coretext",
    "pyobjc-framework-quartz",
}
LINUX_DEPENDENCIES = DIRECT_DEPENDENCIES | {
    "six",
    "evdev",
    "python-xlib",
}
PINNED_REQUIREMENT = re.compile(
    r'^[A-Za-z0-9_.-]+==[^=<>~!;\s]+(?:\s*;\s*sys_platform\s*==\s*"(?:darwin|linux)")?$'
)


def tracked_blobs():
    result = subprocess.run(
        ["git", "ls-files", "--stage", "-z"],
        cwd=PROJECT_DIR,
        capture_output=True,
        check=True,
    )
    blobs = []
    for record in result.stdout.split(b"\0"):
        if not record:
            continue
        metadata, path_bytes = record.split(b"\t", 1)
        _mode, object_id, stage = metadata.split()
        if stage != b"0":
            raise RuntimeError(f"unmerged index entry: {os.fsdecode(path_bytes)}")
        blob = subprocess.run(
            ["git", "cat-file", "blob", object_id.decode("ascii")],
            cwd=PROJECT_DIR,
            capture_output=True,
            check=True,
        ).stdout
        blobs.append((os.fsdecode(path_bytes), blob))
    return blobs


def contains_developer_home_path(data: bytes) -> bool:
    # CI guard for static byte encodings, not a defense against malicious code
    # that constructs a developer path dynamically at runtime.
    slash = b"/"
    backslash = bytes([92])
    user_directory = b"Users"
    patterns = (
        slash + user_directory + slash,
        backslash + slash + user_directory + backslash + slash,
        backslash + b"u002f" + user_directory + backslash + b"u002f",
        b"&#" + b"47;" + user_directory + b"&#" + b"47;",
        b"&#" + b"x2f;" + user_directory + b"&#" + b"x2f;",
        b"%" + b"2f" + user_directory + b"%" + b"2f",
    )
    lowered = data.lower()
    return any(pattern.lower() in lowered for pattern in patterns)


def ignored_paths(paths):
    result = subprocess.run(
        ["git", "check-ignore", "--stdin"],
        cwd=PROJECT_DIR,
        input="\n".join(paths) + "\n",
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise subprocess.CalledProcessError(
            result.returncode,
            result.args,
            output=result.stdout,
            stderr=result.stderr,
        )
    return set(result.stdout.splitlines())


def requirement_lines(path):
    return [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def requirement_names(lines):
    return {line.split("==", 1)[0].lower().replace("_", "-") for line in lines}


def requirement_names_for_platform(lines, platform):
    applicable = []
    marker = f'sys_platform == "{platform}"'
    for line in lines:
        requirement, separator, environment = line.partition(";")
        if not separator or environment.strip() == marker:
            applicable.append(requirement)
    return requirement_names(applicable)


def shared_requirement_versions(lines):
    versions = {}
    for line in lines:
        requirement, separator, _environment = line.partition(";")
        if separator:
            continue
        name, version = requirement.split("==", 1)
        versions[name.lower().replace("_", "-")] = version
    return versions


def normalized_shell_commands(text):
    commands = []
    continuation = ""
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if continuation:
            line = f"{continuation} {line}"
        if line.endswith("\\"):
            continuation = line[:-1].rstrip()
            continue
        commands.append(line)
        continuation = ""
    if continuation:
        commands.append(continuation)
    return commands


def shell_execution_lines(path):
    return normalized_shell_commands(path.read_text(encoding="utf-8"))


def pip_requirement_files(commands):
    requirement_files = []
    for command in commands:
        tokens = shlex.split(command)
        if len(tokens) < 4 or Path(tokens[0]).name not in {"python", "python3"}:
            continue
        if tokens[1:4] != ["-m", "pip", "install"]:
            continue
        arguments = tokens[4:]
        for index, argument in enumerate(arguments[:-1]):
            if argument in {"-r", "--requirement"}:
                requirement_files.append(arguments[index + 1])
    return requirement_files


def load_ci_workflow():
    result = subprocess.run(
        [
            "ruby",
            "-rjson",
            "-ryaml",
            "-e",
            "STDOUT.write(JSON.generate(YAML.safe_load(STDIN.read)))",
        ],
        input=CI_WORKFLOW.read_text(encoding="utf-8"),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(result.stdout)


def ci_job_run_commands(job):
    commands = []
    for step in job["steps"]:
        if "run" in step:
            commands.extend(normalized_shell_commands(step["run"]))
    return commands


def ci_job_run_scripts(job):
    return [step["run"] for step in job["steps"] if "run" in step]


CI_COMMAND_START = r"(?:^|(?:&&|\|\||;|\|)\s*)"
CI_OPTIONAL_SUDO = r"(?:sudo\s+)?"
CI_OPTIONAL_TOOL_PATH = r'(?:"[^"]*/|\'[^\']*/|\S*/)?'
CI_DANGEROUS_COMMAND_PATTERNS = (
    (
        "launchctl service mutation",
        re.compile(
            CI_COMMAND_START
            + CI_OPTIONAL_SUDO
            + CI_OPTIONAL_TOOL_PATH
            + r"launchctl\s+(?:bootstrap|bootout|kickstart|enable|disable|load|unload)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "runtime helper script",
        re.compile(
            CI_COMMAND_START
            + CI_OPTIONAL_SUDO
            + r"(?:(?:ba)?sh\s+)?(?:\./)?scripts/"
            + r"(?:(?:install-launchagent|uninstall-launchagent|run-agent|"
            + r"camera-diagnostic|enroll-owner|lock-now)\.sh|"
            + r"(?:run-agent|camera-diagnostic|enroll-owner)-terminal\.command)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "direct Agent execution",
        re.compile(
            CI_COMMAND_START
            + CI_OPTIONAL_SUDO
            + CI_OPTIONAL_TOOL_PATH
            + r"python(?:3(?:\.\d+)?)?(?:\s+-\S+)*\s+(?:\./)?agent\.py\b",
            re.IGNORECASE,
        ),
    ),
    (
        "CGSession lock",
        re.compile(
            CI_COMMAND_START
            + CI_OPTIONAL_SUDO
            + r'(?:"[^"]*/CGSession"|\'[^\']*/CGSession\'|\S*/CGSession|CGSession)'
            + r"\s+-suspend\b",
            re.IGNORECASE,
        ),
    ),
    (
        "display sleep lock",
        re.compile(
            CI_COMMAND_START
            + CI_OPTIONAL_SUDO
            + CI_OPTIONAL_TOOL_PATH
            + r"pmset\s+displaysleepnow\b",
            re.IGNORECASE,
        ),
    ),
    (
        "AppleScript lock",
        re.compile(
            CI_COMMAND_START
            + CI_OPTIONAL_SUDO
            + CI_OPTIONAL_TOOL_PATH
            + r"osascript\b"
            + r"(?=[^;&|]*(?:keystroke\s+[\"']q[\"']|key\s+code\s+12))"
            + r"(?=[^;&|]*control\s+down)"
            + r"(?=[^;&|]*command\s+down)",
            re.IGNORECASE,
        ),
    ),
    (
        "certificate import",
        re.compile(
            CI_COMMAND_START
            + CI_OPTIONAL_SUDO
            + CI_OPTIONAL_TOOL_PATH
            + r"security\s+import\b",
            re.IGNORECASE,
        ),
    ),
    (
        "code signing",
        re.compile(
            CI_COMMAND_START
            + CI_OPTIONAL_SUDO
            + CI_OPTIONAL_TOOL_PATH
            + r"codesign\b[^;&|]*(?:\s--sign(?:\s|=)|\s-s(?:\s|$))",
            re.IGNORECASE,
        ),
    ),
    (
        "notarization",
        re.compile(
            CI_COMMAND_START
            + CI_OPTIONAL_SUDO
            + r"(?:xcrun\s+)?(?:notarytool|altool)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "unlocked requirements install",
        re.compile(
            CI_COMMAND_START
            + CI_OPTIONAL_SUDO
            + CI_OPTIONAL_TOOL_PATH
            + r"python(?:3(?:\.\d+)?)?\s+-m\s+pip\s+install\b[^;&|]*"
            + r"(?:-r|--requirement)\s+requirements\.txt\b",
            re.IGNORECASE,
        ),
    ),
    (
        "secret reference",
        re.compile(r"\bsecrets\.[A-Za-z_][A-Za-z0-9_]*\b", re.IGNORECASE),
    ),
)


def dangerous_ci_command(command):
    for description, pattern in CI_DANGEROUS_COMMAND_PATTERNS:
        if pattern.search(command):
            return description
    return None


class OpenSourcePolicyTests(unittest.TestCase):
    def test_manual_release_artifact_workflow_is_safe_and_reviewable(self):
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        for token in (
            "workflow_dispatch",
            "macos-15",
            'python-version: "3.11"',
            "PyInstaller==6.21.0",
            "scripts/build-release.sh",
            "Mac-Face-Lock-0.2.0-beta-arm64.zip",
            "actions/upload-artifact@v6",
            "contents: read",
        ):
            self.assertIn(token, workflow)
        for forbidden in (
            "softprops/action-gh-release",
            "gh release create",
            "GITHUB_TOKEN:",
            "contents: write",
        ):
            self.assertNotIn(forbidden, workflow)

    def test_customer_release_documentation_is_complete(self):
        readme = README.read_text(encoding="utf-8")
        customer = (
            PROJECT_DIR / "docs" / "customer-installation.md"
        ).read_text(encoding="utf-8")
        self.assertLess(
            readme.index("普通客户"),
            readme.index("源码开发"),
        )
        for token in (
            "GitHub Releases",
            "无需 Codex、Python、Xcode、终端或源码仓库",
            "右键",
            "SHA-256",
            "摄像头",
            "输入监控",
            "辅助功能",
            "重新录入本人",
            "fail-open",
            "没有活体检测",
            "卸载",
            "彻底删除",
            "scripts/build-release.sh",
            "docs/design-references/mac-face-lock-onboarding-permissions.png",
            "docs/design-references/mac-face-lock-onboarding-enrollment.png",
            "权限确认",
            "不需要单独安装、打开或授权另一个 Agent 应用",
        ):
            self.assertIn(token, readme)
        for token in (
            "Finder",
            "右键",
            "校验",
            "权限中心",
            "录入本人",
            "权限确认",
            "修复",
            "保留数据",
            "彻底删除",
        ):
            self.assertIn(token, customer)

    def test_customer_uninstall_is_a_visible_preserve_data_action(self):
        settings = (PROJECT_DIR / "src" / "app" / "SettingsView.swift").read_text(
            encoding="utf-8"
        )
        coordinator = (
            PROJECT_DIR / "src" / "app" / "SetupCoordinator.swift"
        ).read_text(encoding="utf-8")
        customer = (
            PROJECT_DIR / "docs" / "customer-installation.md"
        ).read_text(encoding="utf-8")
        readme = README.read_text(encoding="utf-8")

        self.assertIn("卸载后台服务并保留数据", settings)
        self.assertIn("uninstallServicePreservingData", settings)
        self.assertIn("func uninstallServicePreservingData()", coordinator)
        for document in (customer, readme):
            self.assertIn("卸载后台服务并保留数据", document)
            self.assertLess(
                document.index("卸载后台服务并保留数据"),
                document.index("废纸篓"),
            )

    def _read_required_document(self, name):
        path = PROJECT_DIR / name
        self.assertTrue(path.is_file(), f"{name} is missing")
        return path.read_text(encoding="utf-8")

    def test_required_open_source_documents_exist(self):
        for name in PUBLIC_DOCUMENTS:
            with self.subTest(name=name):
                self.assertTrue((PROJECT_DIR / name).is_file(), name)

    def test_license_is_standard_mit_for_wuyi(self):
        license_text = self._read_required_document("LICENSE")
        self.assertEqual(license_text, STANDARD_MIT_LICENSE)

    def test_readme_states_beta_and_security_limits(self):
        readme = README.read_text(encoding="utf-8")
        for phrase in ["源码 Beta", "没有活体检测", "不能替代", "通知默认关闭", "MIT"]:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, readme)

    def test_readme_opens_with_local_processing_and_offline_defaults(self):
        introduction = README.read_text(encoding="utf-8").split("\n\n", 2)[1]
        self.assertIn("默认在本机处理", introduction)
        self.assertIn("默认离线", introduction)

    def test_readme_documents_portable_locked_bootstrap(self):
        readme = README.read_text(encoding="utf-8")
        expected_setup = """git clone <repository-url>
cd mac-face-lock-agent
scripts/bootstrap.sh
scripts/enroll-owner.sh
scripts/install-launchagent.sh"""
        self.assertIn(expected_setup, readme)
        self.assertIn("Python 3.9", readme)
        self.assertIn("requirements-lock.txt", readme)
        self.assertIn("不包含 hashes", readme)

    def test_security_policy_states_beta_reporting_and_exclusions(self):
        security = self._read_required_document("SECURITY.md")
        for phrase in [
            "0.1.x Beta",
            "GitHub Security Advisories",
            "fail-open",
            "没有活体检测",
            "高安全",
        ]:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, security)

    def test_security_policy_does_not_claim_an_unverified_private_channel(self):
        security = self._read_required_document("SECURITY.md")
        for phrase in ["尚未启用", "Report a vulnerability", "发布门禁", "实测"]:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, security)
        self.assertNotIn(
            "请通过仓库的 **GitHub Security Advisories** 发起私密报告",
            security,
        )

    def test_contributing_policy_protects_private_runtime_data(self):
        contributing = self._read_required_document("CONTRIBUTING.md")
        for phrase in [
            "完整验证",
            "owner_face.npy",
            "data/evidence/",
            "logs/",
            "隐私安全默认值",
        ]:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, contributing)

    def test_contributing_uses_the_public_platform_baseline(self):
        contributing = self._read_required_document("CONTRIBUTING.md")
        self.assertIn("Apple Silicon", contributing)
        self.assertIn("macOS 12", contributing)

    def test_local_verification_docs_run_all_swift_path_suites(self):
        expected_suites = (
            "tests/swift/LocalStoreSmokeTests.swift",
            "tests/swift/ProjectLocatorTests.swift",
            "tests/swift/AgentLauncherPathTests.swift",
            "tests/swift/UIEventTraceRecorderTests.swift",
            "tests/swift/LocalMouseEventMonitorTests.swift",
        )
        for document in (README, PROJECT_DIR / "CONTRIBUTING.md"):
            text = document.read_text(encoding="utf-8")
            for suite in expected_suites:
                with self.subTest(document=document.name, suite=suite):
                    self.assertIn(suite, text)

    def test_trace_diagnostic_verification_uses_strict_swift_concurrency(self):
        suites = (
            "tests/swift/UIEventTraceRecorderTests.swift",
            "tests/swift/LocalMouseEventMonitorTests.swift",
        )
        for document in (README, PROJECT_DIR / "CONTRIBUTING.md"):
            text = document.read_text(encoding="utf-8")
            for suite in suites:
                with self.subTest(document=document.name, suite=suite):
                    self.assertIn(suite, text)
                    suite_offset = text.index(suite)
                    command_start = text.rfind("xcrun swiftc", 0, suite_offset)
                    command_end = text.find("\n", suite_offset)
                    command = text[command_start:command_end]
                    self.assertIn("-target arm64-apple-macosx12.0", command)
                    self.assertIn("-strict-concurrency=complete", command)
                    self.assertIn("-warn-concurrency", command)
                    self.assertIn("-warnings-as-errors", command)

    def test_changelog_records_initial_source_beta_scope(self):
        changelog = self._read_required_document("CHANGELOG.md")
        for phrase in [
            "Keep a Changelog",
            "[0.1.0-beta] - 2026-07-15",
            "便携安装",
            "统一界面",
            "fail-open",
            "本地数据",
            "仅源码",
        ]:
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, changelog)

    def test_third_party_notices_match_locked_direct_dependencies(self):
        notices = THIRD_PARTY_NOTICES.read_text(encoding="utf-8")
        direct_versions = shared_requirement_versions(requirement_lines(REQUIREMENTS))
        display_names = {
            "numpy": "NumPy",
            "opencv-python": "opencv-python",
            "pynput": "pynput",
        }
        for name, version in direct_versions.items():
            with self.subTest(dependency=name):
                self.assertIn(display_names[name], notices)
                self.assertIn(version, notices)
        self.assertIn("pip", notices)
        self.assertIn("各自许可证", notices)

    def test_third_party_notices_distinguish_wrapper_and_bundled_licenses(self):
        notices = THIRD_PARTY_NOTICES.read_text(encoding="utf-8")
        self.assertRegex(notices, r"NumPy[^\n]*BSD-3-Clause")
        self.assertRegex(notices, r"opencv-python wrapper[^\n]*MIT")
        self.assertRegex(notices, r"OpenCV[^\n]*Apache-2.0")
        self.assertIn("LICENSE.txt", notices)
        self.assertIn("LICENSE-3RD-PARTY.txt", notices)
        self.assertRegex(notices, r"pynput[^\n]*LGPL-3.0-or-later")
        self.assertIn("COPYING.LGPL", notices)

    def test_third_party_notices_attribute_bundled_opencv_version(self):
        notices = THIRD_PARTY_NOTICES.read_text(encoding="utf-8")
        wheel_version = shared_requirement_versions(requirement_lines(REQUIREMENTS))[
            "opencv-python"
        ]
        bundled_version = cv2.__version__
        attribution = (
            f"OpenCV {bundled_version}"
            f"（随 opencv-python {wheel_version} wheel 分发）"
        )

        self.assertRegex(
            notices,
            rf"opencv-python wrapper[^\n]*{re.escape(wheel_version)}[^\n]*MIT",
        )
        self.assertRegex(notices, rf"{re.escape(attribution)}[^\n]*Apache-2.0")
        self.assertNotIn(
            f"| bundled OpenCV（位于 opencv-python wheel） | {wheel_version} |",
            notices,
        )

    def test_lock_records_verified_macos_12_arm64_wheels(self):
        lock = LOCK_REQUIREMENTS.read_text(encoding="utf-8")
        direct_versions = shared_requirement_versions(requirement_lines(REQUIREMENTS))
        expected_wheels = [
            f"numpy-{direct_versions['numpy']}-cp39-cp39-macosx_11_0_arm64.whl",
            f"opencv_python-{direct_versions['opencv-python']}-cp37-abi3-macosx_11_0_arm64.whl",
        ]
        for wheel in expected_wheels:
            with self.subTest(wheel=wheel):
                self.assertIn(wheel, lock)

    def test_direct_versions_keep_supported_dependency_floors(self):
        versions = shared_requirement_versions(requirement_lines(REQUIREMENTS))

        def numeric_prefix(version):
            return tuple(int(part) for part in version.split(".") if part.isdigit())

        self.assertGreaterEqual(numeric_prefix(versions["numpy"]), (1, 24))
        self.assertGreaterEqual(numeric_prefix(versions["opencv-python"]), (4, 8))

    def test_path_detector_finds_common_encoded_forms(self):
        slash = b"/"
        user_directory = b"Users"
        escaped_slash = b"\\" + slash
        unicode_slash = b"\\" + b"u002f"
        xml_slash = b"&#" + b"47;"
        xml_hex_slash = b"&#" + b"x2f;"
        percent_slash = b"%" + b"2f"
        samples = {
            "raw": slash + user_directory + slash + b"developer/project",
            "json-unicode": unicode_slash + user_directory + unicode_slash + b"developer",
            "escaped-slash": escaped_slash + user_directory + escaped_slash + b"developer",
            "xml-decimal": xml_slash + user_directory + xml_slash + b"developer",
            "xml-hex": xml_hex_slash + user_directory + xml_hex_slash + b"developer",
            "percent": percent_slash + user_directory + percent_slash + b"developer",
        }
        for encoding, sample in samples.items():
            with self.subTest(encoding=encoding):
                self.assertTrue(contains_developer_home_path(sample))

    def test_path_detector_allows_bundle_identifiers(self):
        self.assertFalse(contains_developer_home_path(b"com.wuyi.mac-face-lock-agent"))

    def test_tracked_blob_reader_matches_git_index(self):
        blobs = dict(tracked_blobs())
        expected = subprocess.run(
            ["git", "show", ":requirements.txt"],
            cwd=PROJECT_DIR,
            capture_output=True,
            check=True,
        ).stdout
        self.assertEqual(blobs.get("requirements.txt"), expected)

    def test_tracked_files_have_no_encoded_developer_home_path(self):
        offenders = []
        for path, blob in tracked_blobs():
            if contains_developer_home_path(blob):
                offenders.append(path)
        self.assertEqual(offenders, [])

    def test_private_runtime_trees_are_ignored(self):
        expected = {
            "data/owner_face.npy",
            "data/state.json",
            "data/state.random.tmp",
            "data/control.json",
            "data/control.random.tmp",
            "data/activity.jsonl",
            "data/ui-preferences.json",
            "data/evidence/example.jpg",
            "logs/agent.log",
            "logs/subdir/agent.log",
            "logs/launch-migration.example/generated/agent.plist",
            ".venv/bin/python",
            "dist/example",
        }
        actual = ignored_paths(sorted(expected))
        missing = expected - actual
        unexpected = actual - expected
        self.assertSetEqual(
            actual,
            expected,
            f"missing ignores: {sorted(missing)}; unexpected ignores: {sorted(unexpected)}",
        )

    def test_top_level_requirements_are_exactly_pinned(self):
        for line in requirement_lines(REQUIREMENTS):
            self.assertRegex(line, PINNED_REQUIREMENT)

    def test_lock_requirements_are_exactly_pinned(self):
        self.assertTrue(LOCK_REQUIREMENTS.is_file(), "requirements-lock.txt is missing")
        for line in requirement_lines(LOCK_REQUIREMENTS):
            self.assertRegex(line, PINNED_REQUIREMENT)

    def test_lock_covers_direct_and_platform_dependencies(self):
        self.assertTrue(LOCK_REQUIREMENTS.is_file(), "requirements-lock.txt is missing")
        lines = requirement_lines(LOCK_REQUIREMENTS)
        self.assertSetEqual(requirement_names_for_platform(lines, "darwin"), MACOS_DEPENDENCIES)
        self.assertSetEqual(requirement_names_for_platform(lines, "linux"), LINUX_DEPENDENCIES)
        self.assertSetEqual(requirement_names(requirement_lines(REQUIREMENTS)), DIRECT_DEPENDENCIES)

    def test_direct_requirement_versions_match_shared_lock_lines(self):
        direct = shared_requirement_versions(requirement_lines(REQUIREMENTS))
        locked = shared_requirement_versions(requirement_lines(LOCK_REQUIREMENTS))
        locked_direct = {name: version for name, version in locked.items() if name in DIRECT_DEPENDENCIES}
        self.assertSetEqual(set(direct), DIRECT_DEPENDENCIES)
        self.assertSetEqual(set(locked_direct), DIRECT_DEPENDENCIES)
        self.assertDictEqual(direct, locked_direct)

    def test_bootstrap_installs_lock_requirements(self):
        commands = shell_execution_lines(BOOTSTRAP)
        self.assertListEqual(pip_requirement_files(commands), ["requirements-lock.txt"])

    def test_bootstrap_rejects_unsupported_python_with_repair_hint(self):
        commands = shell_execution_lines(BOOTSTRAP)
        self.assertTrue(any("sys.version_info" in line and "(3, 9)" in line for line in commands))
        with tempfile.TemporaryDirectory() as directory:
            fake_python = Path(directory) / "python3"
            fake_python.write_text("#!/usr/bin/env bash\nexit 1\n", encoding="utf-8")
            fake_python.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{directory}:{environment.get('PATH', '')}"
            result = subprocess.run(
                ["bash", str(BOOTSTRAP)],
                cwd=PROJECT_DIR,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Python 3.9", result.stderr)
        self.assertIn("brew install python", result.stderr)
        self.assertIn("PYTHON_BIN=", result.stderr)

    def test_implementation_plan_uses_lock_for_task5_and_task7(self):
        text = IMPLEMENTATION_PLAN.read_text(encoding="utf-8")
        task5 = text.split("### Task 5:", 1)[1].split("\n---\n", 1)[0]
        task7 = text.split("### Task 7:", 1)[1].split("\n---\n", 1)[0]
        self.assertIn("pip install -r requirements-lock.txt", task5)
        self.assertNotIn("pip install -r requirements.txt", task5)
        self.assertGreaterEqual(task7.count("pip install -r requirements-lock.txt"), 3)
        self.assertIn(
            'self.assertNotIn("pip install -r requirements.txt", workflow)',
            task7,
        )

    def test_ci_yaml_parser_is_available(self):
        self.assertIsNotNone(shutil.which("ruby"), "CI policy requires Ruby")
        result = subprocess.run(
            ["ruby", "-rjson", "-ryaml", "-e", "puts JSON.generate({'ok' => true})"],
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertEqual(json.loads(result.stdout), {"ok": True})

    def test_ci_run_command_normalization_ignores_comments_and_joins_continuations(self):
        job = {
            "steps": [
                {"name": "checkout", "uses": "actions/checkout@v4"},
                {
                    "name": "test",
                    "run": """
# scripts/lock-now.sh must never run

python -m unittest discover \\
  -s tests -p 'test_*.py' -v
scripts/bootstrap.sh
""",
                },
            ]
        }

        self.assertListEqual(
            ci_job_run_commands(job),
            [
                "python -m unittest discover -s tests -p 'test_*.py' -v",
                "scripts/bootstrap.sh",
            ],
        )

    def test_ci_dangerous_command_matcher_is_precise(self):
        dangerous = [
            "launchctl bootstrap gui/501 agent.plist",
            "launchctl bootout gui/501/com.example.agent",
            "launchctl kickstart -k gui/501/com.example.agent",
            "launchctl enable gui/501/com.example.agent",
            "launchctl disable gui/501/com.example.agent",
            "launchctl load ~/Library/LaunchAgents/example.plist",
            "launchctl unload ~/Library/LaunchAgents/example.plist",
            "scripts/install-launchagent.sh",
            "bash scripts/uninstall-launchagent.sh",
            "scripts/run-agent.sh",
            "scripts/camera-diagnostic.sh",
            "scripts/enroll-owner.sh",
            "scripts/lock-now.sh",
            "scripts/camera-diagnostic-terminal.command",
            "scripts/enroll-owner-terminal.command",
            "scripts/run-agent-terminal.command",
            ".venv/bin/python -u agent.py --observe",
            '"/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession" -suspend',
            "/usr/bin/pmset displaysleepnow",
            "/usr/bin/osascript -e 'tell application \"System Events\" to keystroke \"q\" using {control down, command down}'",
            "/usr/bin/osascript -e 'tell application \"System Events\" to key code 12 using {command down, control down}'",
            "security import signing.p12 -k build.keychain",
            "codesign --sign - --force Example.app",
            "codesign -s - --force Example.app",
            "codesign -s 'Developer ID Application: Example' Example.app",
            "xcrun notarytool submit Example.zip",
            "xcrun altool --notarize-app --file Example.zip",
            'echo "${{ secrets.APPLE_CERTIFICATE }}"',
            "python -m pip install -r requirements.txt",
        ]
        for command in dangerous:
            with self.subTest(dangerous=command):
                self.assertIsNotNone(dangerous_ci_command(command))

        safe = [
            "scripts/bootstrap.sh",
            "python -m unittest tests.test_agent",
            "python -m unittest tests.test_camera_diagnostic",
            "launchctl print gui/501/com.example.agent",
            'codesign --verify --deep --strict "Example.app"',
            "/usr/bin/osascript -e 'display notification \"CI complete\"'",
            "echo scripts/lock-now.sh",
            "echo bootstrap camera enroll",
        ]
        for command in safe:
            with self.subTest(safe=command):
                self.assertIsNone(dangerous_ci_command(command))

    def test_ci_runs_python_and_macos_release_gates(self):
        workflow = load_ci_workflow()
        self.assertIn("on", workflow, "quote the YAML 'on' key for Ruby Psych")
        self.assertSetEqual(set(workflow["on"]), {"push", "pull_request"})
        self.assertDictEqual(workflow["permissions"], {"contents": "read"})

        jobs = workflow["jobs"]
        linux = jobs["python-linux"]
        macos = jobs["macos-release-gates"]
        self.assertEqual(linux["runs-on"], "ubuntu-latest")
        self.assertEqual(macos["runs-on"], "macos-15")

        for build_script in (
            PROJECT_DIR / "scripts" / "build-app.sh",
            PROJECT_DIR / "scripts" / "build-status-app.sh",
        ):
            with self.subTest(build_script=build_script.name):
                self.assertIn(
                    "-target arm64-apple-macosx12.0",
                    build_script.read_text(encoding="utf-8"),
                )

        linux_commands = ci_job_run_commands(linux)
        macos_commands = ci_job_run_commands(macos)

        def assert_command(job, commands, pattern):
            self.assertTrue(
                any(re.search(pattern, command) for command in commands),
                f"{job} is missing command matching {pattern!r}: {commands}",
            )

        shared_patterns = [
            r"^python -m pip install -r requirements-lock\.txt$",
            r"^python -m unittest discover -s tests -p 'test_\*\.py' -v$",
        ]
        for pattern in shared_patterns:
            with self.subTest(job="linux", pattern=pattern):
                assert_command("linux", linux_commands, pattern)
            with self.subTest(job="macos", pattern=pattern):
                assert_command("macos", macos_commands, pattern)

        for pattern in [
            r"^sudo apt-get update && sudo apt-get install\b.*\bbuild-essential\b",
            r"^sudo apt-get update && sudo apt-get install\b.*\blinux-libc-dev\b",
            r"^sudo apt-get update && sudo apt-get install\b.*\blibgl1\b",
            r"^sudo apt-get update && sudo apt-get install\b.*\blibglib2\.0-0\b",
            r"^python -m compileall -q -x ",
            r"^bash -n scripts/\*\.sh scripts/\*\.command$",
        ]:
            with self.subTest(job="linux", pattern=pattern):
                assert_command("linux", linux_commands, pattern)

        for pattern in [
            r"^xcrun swiftc\b.*\btests/swift/LocalStoreSmokeTests\.swift\b",
            r"^xcrun swiftc\b.*\btests/swift/ProjectLocatorTests\.swift\b",
            r"^xcrun swiftc\b.*\btests/swift/AgentLauncherPathTests\.swift\b",
            r"^xcrun swiftc\b.*-target arm64-apple-macosx12\.0\b.*-strict-concurrency=complete\b.*-warn-concurrency\b.*-warnings-as-errors\b.*\btests/swift/UIEventTraceRecorderTests\.swift\b",
            r"^xcrun swiftc\b.*-target arm64-apple-macosx12\.0\b.*-strict-concurrency=complete\b.*-warn-concurrency\b.*-warnings-as-errors\b.*\btests/swift/LocalMouseEventMonitorTests\.swift\b",
            r"^xcrun swiftc -parse-as-library -typecheck\b",
            r"^scripts/build-status-app\.sh$",
            r"^plutil -lint\b",
            r'^codesign --verify --deep --strict "dist/Mac Face Lock\.app"$',
            r'^build_info="\$\(xcrun vtool -show-build "\$executable"\)"$',
        ]:
            with self.subTest(job="macos", pattern=pattern):
                assert_command("macos", macos_commands, pattern)

        for forbidden in (
            "scripts/build-app.sh",
            'dist/Mac Face Lock Agent.app/Contents/Info.plist',
            'codesign --verify --deep --strict "dist/Mac Face Lock Agent.app"',
            'dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent',
        ):
            with self.subTest(job="macos", forbidden=forbidden):
                self.assertFalse(
                    any(forbidden in command for command in macos_commands),
                    f"macos release gate still depends on {forbidden!r}: {macos_commands}",
                )

    def test_ci_builds_runtime_only_on_macos_before_unified_app(self):
        workflow = load_ci_workflow()
        linux_commands = ci_job_run_commands(workflow["jobs"]["python-linux"])
        macos_job = workflow["jobs"]["macos-release-gates"]
        macos_commands = ci_job_run_commands(macos_job)

        self.assertNotIn("scripts/build-runtime.sh", linux_commands)
        uv_steps = [
            index
            for index, step in enumerate(macos_job["steps"])
            if step.get("uses")
            == "astral-sh/setup-uv@08807647e7069bb48b6ef5acd8ec9567f424441b"
        ]
        self.assertEqual(uv_steps, [2], "macOS must install the pinned uv action")
        uv_step_index = uv_steps[0]
        self.assertEqual(
            macos_job["steps"][uv_step_index].get("with", {}).get("version"),
            "0.11.13",
        )
        runtime_step_index = next(
            index
            for index, step in enumerate(macos_job["steps"])
            if step.get("run") == "scripts/build-runtime.sh"
        )
        self.assertLess(uv_step_index, runtime_step_index)
        runtime_index = macos_commands.index("scripts/build-runtime.sh")
        prerequisites_index = macos_commands.index(
            "python -m pip install -r requirements-lock.txt"
        )
        unified_app_index = macos_commands.index("scripts/build-status-app.sh")
        self.assertGreater(runtime_index, prerequisites_index)
        self.assertLess(runtime_index, unified_app_index)

    def test_ci_uses_node24_action_majors(self):
        workflow = load_ci_workflow()
        expected = {
            "actions/checkout": "actions/checkout@v6",
            "actions/setup-python": "actions/setup-python@v6",
        }
        for job_name, job in workflow["jobs"].items():
            uses = {
                step["uses"].split("@", 1)[0]: step["uses"]
                for step in job["steps"]
                if "uses" in step
            }
            for action, version in expected.items():
                with self.subTest(job=job_name, action=action):
                    self.assertEqual(uses.get(action), version)

    def test_ci_run_commands_exclude_dangerous_runtime_and_release_actions(self):
        workflow = load_ci_workflow()
        run_commands = [
            command
            for job in workflow["jobs"].values()
            for command in ci_job_run_commands(job)
        ]
        for command in run_commands:
            with self.subTest(command=command):
                self.assertIsNone(
                    dangerous_ci_command(command),
                    f"dangerous CI run command: {command}",
                )

    def test_ci_minos_gate_accepts_only_an_exact_macos_12_field(self):
        workflow = load_ci_workflow()
        macos_scripts = ci_job_run_scripts(
            workflow["jobs"]["macos-release-gates"]
        )
        minos_scripts = [
            script for script in macos_scripts if "vtool -show-build" in script
        ]
        self.assertEqual(len(minos_scripts), 1)
        script = minos_scripts[0]

        with tempfile.TemporaryDirectory() as directory:
            fake_bin = Path(directory)
            xcrun = fake_bin / "xcrun"
            xcrun.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "[[ \"$1\" == \"vtool\" && \"$2\" == \"-show-build\" ]]\n"
                "printf '%s\\n' \"$FAKE_VTOOL_OUTPUT\"\n",
                encoding="utf-8",
            )
            xcrun.chmod(0o755)
            base_environment = os.environ.copy()
            base_environment["PATH"] = f"{fake_bin}:{base_environment['PATH']}"

            cases = {
                "exact": (
                    "Load command 11\n"
                    "      cmd LC_BUILD_VERSION\n"
                    " platform MACOS\n"
                    "    minos 12.0\n"
                    "      sdk 15.0",
                    0,
                ),
                "missing": ("Load command 11\n platform MACOS\n sdk 15.0", 1),
                "prefix-boundary": ("minos 12.01", 1),
                "newer": ("minos 13.0", 1),
            }
            for name, (output, expected_returncode) in cases.items():
                environment = base_environment.copy()
                environment["FAKE_VTOOL_OUTPUT"] = output
                result = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", script],
                    cwd=PROJECT_DIR,
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                with self.subTest(case=name):
                    if expected_returncode == 0:
                        self.assertEqual(result.returncode, 0, result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
