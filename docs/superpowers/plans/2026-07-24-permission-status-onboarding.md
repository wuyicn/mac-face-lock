# Permission Status Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the blocking user-facing security-test step with permission-state confirmation after owner enrollment.

**Architecture:** Keep the persisted `safety_test` step for compatibility, but change its UI meaning to permission confirmation. Readiness will require owner profile, three required permissions, and service health; diagnosis and owner verification remain observable diagnostics and are no longer user-facing completion gates.

**Tech Stack:** Swift, SwiftUI, XCTest-style executable Swift fixtures, existing `SetupCoordinator` and `SetupReadiness` models.

## Global Constraints

- Keep one visible `Mac Face Lock` permission identity.
- Do not modify macOS TCC records or toggle permissions automatically.
- Protection must remain disabled until the existing live enable gate succeeds.
- Preserve existing onboarding records and historical `safety_test` values.

### Task 1: Change readiness contract and coordinator completion path

**Files:**
- Modify: `src/app/SetupModels.swift`
- Modify: `src/app/SetupCoordinator.swift`
- Test: `tests/swift/SetupStateTests.swift`
- Test: `tests/swift/SetupCoordinatorTests.swift`

**Interfaces:**
- Add `SetupCoordinator.completePermissionStatusStep() async -> Bool`.
- `SetupReadiness.requiredChecks` must include owner profile, three required permissions, and service health, but not diagnosis or owner test.

- [ ] **Step 1: Write failing tests** for permission-only readiness and completion without calling `runSafetyTest`.
- [ ] **Step 2: Run the focused Swift model/coordinator test commands and confirm the new assertions fail.**
- [ ] **Step 3: Implement the minimal readiness and coordinator changes.** The new method refreshes permissions/service, verifies owner profile, persists `.completion` using the existing record format, and leaves protection disabled.
- [ ] **Step 4: Run the focused tests again and confirm they pass.**
- [ ] **Step 5: Commit** with `git commit -m "feat: make permission status the onboarding gate"`.

### Task 2: Replace the blocking UI with permission status

**Files:**
- Modify: `src/app/OnboardingView.swift`
- Modify: `src/app/SettingsView.swift`
- Test: `tests/test_open_source_policy.py` if copy/flow policy assertions require updates

**Interfaces:**
- The safety-test view becomes a permission-confirmation view and invokes `completePermissionStatusStep()`.

- [ ] **Step 1: Add/update UI copy assertions for the absence of the blocking security-test action.**
- [ ] **Step 2: Run the focused policy/UI source tests and confirm the pre-change expectation fails.**
- [ ] **Step 3: Change the view title, subtitle, status rows, action label, and recovery copy; retain permission settings actions.**
- [ ] **Step 4: Run focused UI/policy tests and confirm they pass.**
- [ ] **Step 5: Commit** with `git commit -m "feat: show permission status during onboarding"`.

### Task 3: Full verification and release evidence

**Files:**
- Verify: `src/app/SetupModels.swift`, `src/app/SetupCoordinator.swift`, `src/app/OnboardingView.swift`, `src/app/SettingsView.swift`
- Verify: `dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip`

- [ ] **Step 1: Run the complete Swift matrix and Python suite.**
- [ ] **Step 2: Build the release package and run automatic preflight, checksum, deep signature, manifest, and single-identity checks.**
- [ ] **Step 3: Reinstall recoverably only after the artifact passes; preserve all prior app copies and support data.**
- [ ] **Step 4: Verify live state: background job running, owner hash unchanged, permissions shown accurately, protection false.**
- [ ] **Step 5: Commit/report evidence without pushing.**
