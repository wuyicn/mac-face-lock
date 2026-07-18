#!/usr/bin/env python3
from __future__ import annotations

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
    "Library/LaunchAgents": (
        "src/app/ServiceManager.swift",
        1,
        """
        launchAgentsURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/LaunchAgents",
                    isDirectory: true
                )
        """,
    ),
    "ProgramArguments": (
        "src/app/ServiceManager.swift",
        1,
        'let arguments = dictionary["ProgramArguments"] as? [String]',
    ),
    ".venv": (
        "src/app/AppEnvironment.swift",
        1,
        'runtimeExecutableURL: root.appendingPathComponent(".venv/bin/python")',
    ),
    NOTICE: (
        "src/app/OnboardingView.swift",
        1,
        f'Text("{NOTICE}")',
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
        for forbidden in MIGRATION_FORBIDDEN:
            searchable_forbidden = (
                normalize_swift_policy_text(forbidden) if is_swift else forbidden
            )
            if searchable_forbidden in searchable_content:
                violations.append(
                    f"{source_name}: forbidden migration symbol/action "
                    f"'{forbidden}'"
                )

    for anchor, budget in SWIFT_SENSITIVE_ANCHOR_BUDGETS.items():
        expected_source, expected_count, expected_context = budget
        normalized_anchor = normalize_swift_policy_text(anchor)
        expected_content = normalized_swift_sources.get(expected_source, "")
        actual_count = expected_content.count(normalized_anchor)
        if actual_count != expected_count:
            violations.append(
                f"{expected_source}: normalized sensitive anchor '{anchor}' "
                f"expected exactly {expected_count} occurrence, found {actual_count}"
            )

        normalized_context = normalize_swift_policy_text(expected_context)
        context_count = expected_content.count(normalized_context)
        if context_count != expected_count:
            violations.append(
                f"{expected_source}: normalized context budget for sensitive "
                f"anchor '{anchor}' expected exactly {expected_count} occurrence, "
                f"found {context_count}"
            )

        for source_name, normalized_content in sorted(
            normalized_swift_sources.items()
        ):
            if source_name == expected_source:
                continue
            unexpected_count = normalized_content.count(normalized_anchor)
            if unexpected_count:
                violations.append(
                    f"{source_name}: normalized sensitive anchor '{anchor}' "
                    f"is not allowed; expected exactly {expected_count} occurrence "
                    f"in {expected_source}"
                )
    return violations


class LegacyMigrationDeferralTests(unittest.TestCase):
    def test_normalized_detector_rejects_split_launch_agents_anchor(self) -> None:
        sources = load_policy_sources()
        sources["src/app/LegacyProbe.swift"] = (
            'let legacyLaunchAgents = "Library" + "/" + "LaunchAgents"'
        )

        violations = collect_policy_violations(sources)

        self.assertIn(
            "src/app/LegacyProbe.swift: normalized sensitive anchor "
            "'Library/LaunchAgents' is not allowed; expected exactly "
            "1 occurrence in src/app/ServiceManager.swift",
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
            "Library/LaunchAgents": "src/app/ServiceManager.swift",
            "ProgramArguments": "src/app/ServiceManager.swift",
            ".venv": "src/app/AppEnvironment.swift",
            NOTICE: "src/app/OnboardingView.swift",
        }

        for anchor, allowed_source in probes.items():
            with self.subTest(anchor=anchor):
                sources = load_policy_sources()
                sources["src/app/LegacyProbe.swift"] = f'let probe = "{anchor}"'
                violations = collect_policy_violations(sources)
                self.assertIn(
                    "src/app/LegacyProbe.swift: normalized sensitive anchor "
                    f"'{anchor}' is not allowed; expected exactly 1 occurrence "
                    f"in {allowed_source}",
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
