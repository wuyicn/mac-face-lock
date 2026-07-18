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
