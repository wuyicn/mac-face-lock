#!/usr/bin/env python3
from __future__ import annotations

import re
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
NOTICE = (
    "如果您使用过源码测试版，本版本不会自动读取或迁移旧数据。"
    "请重新录入本人并完成安全测试；原目录和数据将保持不变。"
)
MIGRATION_FORBIDDEN = (
    "SourceDataMigrator",
    "SourceDataMigrationError",
    "SourceDataMigrationResult",
    "SourceInstallCandidate",
    "MigrationItem",
    "MigrationDecision",
    "sourceInstallCandidates",
    "migrationDecision",
    "sourceDataMigrator",
    "importSourceData",
    "skipSourceDataImport",
    "retryMigrationRecovery",
    "recoverPendingImports",
    "discoverCandidates",
    "发现旧版源码数据",
    "导入旧版数据",
    "跳过导入",
    "重试恢复",
    "source-data-migration",
)
SWIFT_SENSITIVE_ANCHOR_BUDGETS = {
    "Library/LaunchAgents": {
        "src/app/ServiceManager.swift": (
            1,
            """
            launchAgentsURL
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Library/LaunchAgents",
                        isDirectory: true
                    )
            """,
            1,
        ),
        "src/app/LegacyInstallCleaner.swift": (
            1,
            """
            homeURL.appendingPathComponent(
                "Library/LaunchAgents",
                isDirectory: true
            )
            """,
            1,
        ),
    },
    "ProgramArguments": {
        "src/app/ServiceManager.swift": (
            1,
            'let arguments = dictionary["ProgramArguments"] as? [String]',
            1,
        ),
        "src/app/LegacyInstallCleaner.swift": (
            6,
            'dictionary["ProgramArguments"] as? [String]',
            3,
        ),
    },
    ".venv": {
        "src/app/AppEnvironment.swift": (
            1,
            'runtimeExecutableURL: root.appendingPathComponent(".venv/bin/python")',
            1,
        ),
        "src/app/LegacyInstallCleaner.swift": (
            1,
            'relativeComponents[relativeComponents.startIndex] == ".venv"',
            1,
        ),
    },
    "readRegularFile": {
        "src/app/SecureFileTree.swift": (
            1,
            """
            func readRegularFile(
                _ relativePath: String,
                maximumBytes: Int
            ) throws -> Data
            """,
            1,
        ),
        "src/app/LegacyInstallCleaner.swift": (
            1,
            """
            tree.readRegularFile(
                name,
                maximumBytes: LegacyIdentity.maximumPlistBytes
            )
            """,
            1,
        ),
    },
    NOTICE: {
        "src/app/OnboardingView.swift": (
            1,
            f'Text("{NOTICE}")',
            1,
        ),
    },
}
SECURE_FILE_TREE_SOURCE = "src/app/SecureFileTree.swift"
DIRECTORY_ENUMERATION_CAPABILITIES = {
    "contentsOfDirectory": (
        re.compile(r"\bcontentsOfDirectory\s*\("),
        frozenset(),
    ),
    "enumerator(": (
        re.compile(r"\benumerator\s*\("),
        frozenset(),
    ),
    "subpathsOfDirectory": (
        re.compile(r"\bsubpathsOfDirectory\s*\("),
        frozenset(),
    ),
}
NORMALIZED_DIRECTORY_ENUMERATION_CAPABILITIES = {
    "subpaths(atPath:)": "subpathsatPath",
}
FILE_READ_CAPABILITIES = {
    "Data(contentsOf:)": (
        re.compile(r"\bData\s*\(\s*contentsOf\s*:"),
        frozenset(
            {
                "src/app/LocalJSONStore.swift",
                "src/app/ServiceManager.swift",
                "src/app/SetupCoordinator.swift",
            }
        ),
    ),
    "String(contentsOf:)": (
        re.compile(r"\bString\s*\(\s*contentsOf\s*:"),
        frozenset(),
    ),
    "FileHandle(forReadingFrom:)": (
        re.compile(r"\bFileHandle\s*\(\s*forReadingFrom\s*:"),
        frozenset({"src/app/LocalJSONStore.swift"}),
    ),
    "contents(atPath:)": (
        re.compile(r"\bcontents\s*\(\s*atPath\s*:"),
        frozenset(),
    ),
    "Darwin/POSIX open": (
        re.compile(
            r"(?:\b(?:Darwin|Glibc)\s*\.\s*open|(?<![\w.])open)"
            r"\s*\(\s*[^,\n]+,\s*(?:O_[A-Z0-9_| ]+|[0-9]+)"
        ),
        frozenset({SECURE_FILE_TREE_SOURCE}),
    ),
    "Darwin/POSIX openat": (
        re.compile(
            r"(?:\b(?:Darwin|Glibc)\s*\.\s*openat|(?<![\w.])openat)\s*\("
        ),
        frozenset({SECURE_FILE_TREE_SOURCE}),
    ),
    "Darwin/POSIX read": (
        re.compile(
            r"(?:\b(?:Darwin|Glibc)\s*\.\s*read|(?<![\w.])read)"
            r"\s*\(\s*[^,\n]+,\s*[^,\n]+,\s*[^)\n]+\)"
        ),
        frozenset({SECURE_FILE_TREE_SOURCE}),
    ),
    "Darwin/POSIX fstatat": (
        re.compile(
            r"(?:\b(?:Darwin|Glibc)\s*\.\s*fstatat|(?<![\w.])fstatat)\s*\("
        ),
        frozenset({SECURE_FILE_TREE_SOURCE}),
    ),
    "Darwin/POSIX fdopendir": (
        re.compile(
            r"(?:\b(?:Darwin|Glibc)\s*\.\s*fdopendir|(?<![\w.])fdopendir)"
            r"\s*\("
        ),
        frozenset({SECURE_FILE_TREE_SOURCE}),
    ),
    "Darwin/POSIX readdir": (
        re.compile(
            r"(?:\b(?:Darwin|Glibc)\s*\.\s*readdir|(?<![\w.])readdir)\s*\("
        ),
        frozenset({SECURE_FILE_TREE_SOURCE}),
    ),
    "Darwin/POSIX unlinkat": (
        re.compile(
            r"(?:\b(?:Darwin|Glibc)\s*\.\s*unlinkat|(?<![\w.])unlinkat)\s*\("
        ),
        frozenset({SECURE_FILE_TREE_SOURCE}),
    ),
}


def normalize_swift_policy_text(text: str) -> str:
    return "".join(
        character
        for character in text
        if character.isalnum() or character == "."
    )


def load_policy_sources() -> dict[str, str]:
    swift_sources = {
        path.relative_to(PROJECT_DIR).as_posix(): path.read_text()
        for path in sorted((PROJECT_DIR / "src/app").glob("*.swift"))
    }
    workflow_path = PROJECT_DIR / ".github/workflows/ci.yml"
    return {
        **swift_sources,
        workflow_path.relative_to(
            PROJECT_DIR
        ).as_posix(): workflow_path.read_text(),
    }


def collect_policy_violations(sources: dict[str, str]) -> list[str]:
    violations: list[str] = []
    normalized_swift_sources: dict[str, str] = {}
    for source_name, content in sorted(sources.items()):
        is_swift = source_name.endswith(".swift")
        searchable_content = (
            normalize_swift_policy_text(content) if is_swift else content
        )
        if is_swift:
            normalized_swift_sources[source_name] = searchable_content
            for capability, policy in DIRECTORY_ENUMERATION_CAPABILITIES.items():
                expression, allowed_sources = policy
                if expression.search(content) and source_name not in allowed_sources:
                    violations.append(
                        f"{source_name}: directory-enumeration capability "
                        f"'{capability}' is forbidden"
                    )
            for (
                capability,
                normalized_needle,
            ) in NORMALIZED_DIRECTORY_ENUMERATION_CAPABILITIES.items():
                if normalized_needle in searchable_content:
                    violations.append(
                        f"{source_name}: directory-enumeration capability "
                        f"'{capability}' is forbidden"
                    )
            for capability, policy in FILE_READ_CAPABILITIES.items():
                expression, allowed_sources = policy
                if expression.search(content) and source_name not in allowed_sources:
                    allowed_label = ", ".join(sorted(allowed_sources)) or "no files"
                    violations.append(
                        f"{source_name}: direct file-read capability "
                        f"'{capability}' is not allowed; allowed only in "
                        f"{allowed_label}"
                    )
        for forbidden in MIGRATION_FORBIDDEN:
            searchable_forbidden = (
                normalize_swift_policy_text(forbidden) if is_swift else forbidden
            )
            if searchable_forbidden in searchable_content:
                violations.append(
                    f"{source_name}: forbidden migration symbol/action "
                    f"'{forbidden}'"
                )

    for anchor, source_budgets in SWIFT_SENSITIVE_ANCHOR_BUDGETS.items():
        normalized_anchor = normalize_swift_policy_text(anchor)
        for expected_source, budget in sorted(source_budgets.items()):
            expected_count, expected_context, expected_context_count = budget
            expected_content = normalized_swift_sources.get(expected_source, "")
            actual_count = expected_content.count(normalized_anchor)
            if actual_count != expected_count:
                violations.append(
                    f"{expected_source}: normalized sensitive anchor '{anchor}' "
                    f"expected exactly {expected_count} occurrence, found "
                    f"{actual_count}"
                )

            normalized_context = normalize_swift_policy_text(expected_context)
            context_count = expected_content.count(normalized_context)
            if context_count != expected_context_count:
                violations.append(
                    f"{expected_source}: normalized context budget for sensitive "
                    f"anchor '{anchor}' expected exactly {expected_context_count} "
                    f"occurrence, found {context_count}"
                )

        for source_name, normalized_content in sorted(
            normalized_swift_sources.items()
        ):
            if source_name in source_budgets:
                continue
            unexpected_count = normalized_content.count(normalized_anchor)
            if unexpected_count:
                allowed_label = ", ".join(sorted(source_budgets))
                violations.append(
                    f"{source_name}: normalized sensitive anchor '{anchor}' "
                    f"is not allowed; allowed only in {allowed_label}"
                )
    return violations


class LegacyCleanupPolicyTests(unittest.TestCase):
    def test_directory_enumeration_rejects_whitespace_subpaths_at_path(
        self,
    ) -> None:
        sources = load_policy_sources()
        sources["src/app/LegacyProbe.swift"] = """
let legacyEntries = fileManager.subpaths (
    atPath : legacyRoot.path
)
"""

        violations = collect_policy_violations(sources)

        self.assertIn(
            "src/app/LegacyProbe.swift: directory-enumeration capability "
            "'subpaths(atPath:)' is forbidden",
            violations,
        )

    def test_file_read_capability_rejects_chained_launchagents_helper(self) -> None:
        sources = load_policy_sources()
        sources["src/app/LegacyProbe.swift"] = """
let legacyPlist = home
    .appendingPathComponent("Library")
    .appendingPathComponent("LaunchAgents")
    .appendingPathComponent("com.wuyi.mac-face-lock-status.plist")
let legacyData = try Data(contentsOf: legacyPlist)
"""

        violations = collect_policy_violations(sources)

        self.assertIn(
            "src/app/LegacyProbe.swift: direct file-read capability "
            "'Data(contentsOf:)' is not allowed; allowed only in "
            "src/app/LocalJSONStore.swift, src/app/ServiceManager.swift, "
            "src/app/SetupCoordinator.swift",
            violations,
        )

    def test_posix_file_reader_is_allowed_only_in_secure_file_tree(self) -> None:
        probe = """
let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
var buffer = [UInt8](repeating: 0, count: 32)
_ = read(descriptor, &buffer, buffer.count)
"""
        sources = load_policy_sources()
        sources["src/app/LegacyProbe.swift"] = probe

        violations = collect_policy_violations(sources)

        self.assertIn(
            "src/app/LegacyProbe.swift: direct file-read capability "
            "'Darwin/POSIX open' is not allowed; allowed only in "
            "src/app/SecureFileTree.swift",
            violations,
        )
        self.assertIn(
            "src/app/LegacyProbe.swift: direct file-read capability "
            "'Darwin/POSIX read' is not allowed; allowed only in "
            "src/app/SecureFileTree.swift",
            violations,
        )

    def test_qualified_posix_tree_primitives_are_allowed_only_in_secure_file_tree(
        self,
    ) -> None:
        probes = {
            "Darwin/POSIX openat": "openat(parent, name, O_RDONLY)",
            "Darwin/POSIX fstatat": (
                "fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW)"
            ),
            "Darwin/POSIX fdopendir": "fdopendir(descriptor)",
            "Darwin/POSIX readdir": "readdir(directory)",
            "Darwin/POSIX unlinkat": "unlinkat(parent, name, 0)",
        }

        for capability, call in probes.items():
            for namespace in ("Darwin", "Glibc"):
                with self.subTest(capability=capability, namespace=namespace):
                    sources = load_policy_sources()
                    sources["src/app/LegacyProbe.swift"] = (
                        f"_ = {namespace}.{call}"
                    )

                    violations = collect_policy_violations(sources)

                    self.assertIn(
                        "src/app/LegacyProbe.swift: direct file-read capability "
                        f"'{capability}' is not allowed; allowed only in "
                        "src/app/SecureFileTree.swift",
                        violations,
                    )

    def test_normalized_detector_rejects_split_launch_agents_anchor(self) -> None:
        sources = load_policy_sources()
        sources["src/app/LegacyProbe.swift"] = (
            'let legacyLaunchAgents = "Library" + "/" + "LaunchAgents"'
        )

        violations = collect_policy_violations(sources)

        self.assertIn(
            "src/app/LegacyProbe.swift: normalized sensitive anchor "
            "'Library/LaunchAgents' is not allowed; allowed only in "
            "src/app/LegacyInstallCleaner.swift, src/app/ServiceManager.swift",
            violations,
        )

    def test_sensitive_anchor_budget_rejects_second_allowed_file_occurrence(
        self,
    ) -> None:
        sources = load_policy_sources()
        service_manager = "src/app/ServiceManager.swift"
        sources[service_manager] += """
private func readLegacyPlistStatus() {
    let legacyLaunchAgents = "Library/LaunchAgents"
    let legacyArguments = "ProgramArguments"
}
"""

        violations = collect_policy_violations(sources)

        self.assertIn(
            "src/app/ServiceManager.swift: normalized sensitive anchor "
            "'Library/LaunchAgents' expected exactly 1 occurrence, found 2",
            violations,
        )
        self.assertIn(
            "src/app/ServiceManager.swift: normalized sensitive anchor "
            "'ProgramArguments' expected exactly 1 occurrence, found 2",
            violations,
        )

    def test_sensitive_anchor_detector_rejects_new_swift_helper(self) -> None:
        probes = {
            "Library/LaunchAgents": (
                "src/app/LegacyInstallCleaner.swift, "
                "src/app/ServiceManager.swift"
            ),
            "ProgramArguments": (
                "src/app/LegacyInstallCleaner.swift, "
                "src/app/ServiceManager.swift"
            ),
            ".venv": (
                "src/app/AppEnvironment.swift, "
                "src/app/LegacyInstallCleaner.swift"
            ),
            "readRegularFile": (
                "src/app/LegacyInstallCleaner.swift, "
                "src/app/SecureFileTree.swift"
            ),
            NOTICE: "src/app/OnboardingView.swift",
        }

        for anchor, allowed_sources in probes.items():
            with self.subTest(anchor=anchor):
                sources = load_policy_sources()
                sources["src/app/LegacyProbe.swift"] = f'let probe = "{anchor}"'
                violations = collect_policy_violations(sources)
                self.assertIn(
                    "src/app/LegacyProbe.swift: normalized sensitive anchor "
                    f"'{anchor}' is not allowed; allowed only in "
                    f"{allowed_sources}",
                    violations,
                )

    def test_release_onboarding_defers_automatic_source_beta_migration(self) -> None:
        sources = load_policy_sources()
        onboarding = sources["src/app/OnboardingView.swift"]

        self.assertIn(NOTICE, onboarding)
        self.assertFalse((PROJECT_DIR / "src/app/SourceDataMigrator.swift").exists())
        self.assertFalse(
            (PROJECT_DIR / "tests/swift/SourceDataMigratorTests.swift").exists()
        )
        violations = collect_policy_violations(sources)
        self.assertEqual(violations, [], "\n".join(violations))


if __name__ == "__main__":
    unittest.main()
