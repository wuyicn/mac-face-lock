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
SWIFT_SENSITIVE_ANCHOR_ALLOWLIST = {
    "Library/LaunchAgents": frozenset({"ServiceManager.swift"}),
    "ProgramArguments": frozenset({"ServiceManager.swift"}),
    ".venv": frozenset({"AppEnvironment.swift"}),
    NOTICE: frozenset({"OnboardingView.swift"}),
}


def collect_policy_violations(sources: dict[str, str]) -> list[str]:
    violations: list[str] = []
    for source_name, content in sorted(sources.items()):
        for forbidden in MIGRATION_FORBIDDEN:
            if forbidden in content:
                violations.append(
                    f"{source_name}: forbidden migration symbol/action "
                    f"'{forbidden}'"
                )

        if not source_name.endswith(".swift"):
            continue
        file_name = Path(source_name).name
        for anchor, allowed_files in SWIFT_SENSITIVE_ANCHOR_ALLOWLIST.items():
            if anchor in content and file_name not in allowed_files:
                allowed_label = ", ".join(sorted(allowed_files))
                violations.append(
                    f"{source_name}: sensitive anchor '{anchor}' "
                    f"is only allowed in {allowed_label}"
                )
    return violations


class LegacyMigrationDeferralTests(unittest.TestCase):
    def test_sensitive_anchor_detector_rejects_new_swift_helper(self) -> None:
        probes = {
            "Library/LaunchAgents": "ServiceManager.swift",
            "ProgramArguments": "ServiceManager.swift",
            ".venv": "AppEnvironment.swift",
            NOTICE: "OnboardingView.swift",
        }

        for anchor, allowed_file in probes.items():
            with self.subTest(anchor=anchor):
                violations = collect_policy_violations(
                    {"src/app/LegacyProbe.swift": f'let probe = "{anchor}"'}
                )
                self.assertEqual(
                    violations,
                    [
                        "src/app/LegacyProbe.swift: sensitive anchor "
                        f"'{anchor}' is only allowed in {allowed_file}"
                    ],
                )

    def test_release_onboarding_defers_automatic_source_beta_migration(self) -> None:
        swift_sources = {
            path.relative_to(PROJECT_DIR).as_posix(): path.read_text()
            for path in sorted((PROJECT_DIR / "src/app").glob("*.swift"))
        }
        workflow_path = PROJECT_DIR / ".github/workflows/ci.yml"
        sources = {
            **swift_sources,
            workflow_path.relative_to(PROJECT_DIR).as_posix(): workflow_path.read_text(),
        }
        onboarding = swift_sources["src/app/OnboardingView.swift"]

        self.assertIn(NOTICE, onboarding)
        self.assertFalse((PROJECT_DIR / "src/app/SourceDataMigrator.swift").exists())
        self.assertFalse(
            (PROJECT_DIR / "tests/swift/SourceDataMigratorTests.swift").exists()
        )
        violations = collect_policy_violations(sources)
        self.assertEqual(violations, [], "\n".join(violations))


if __name__ == "__main__":
    unittest.main()
