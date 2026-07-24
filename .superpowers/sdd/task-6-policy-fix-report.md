# Task 6 safety-policy regression fix

**Status:** PASS. Both blocking full-Python policy regressions are fixed without
changing policy budgets or allowlists. No live app, install, launchctl, TCC,
settings, user data, protection state, release rebuild, push, merge, or deploy
action was performed.

## Root causes

1. `SetupCoordinator.swift` acquired direct `open`, `openat`, `read`,
   `fstatat`, and `unlinkat` capabilities in `6544aaa` for enrollment owner
   snapshot/rollback. Those generic privileged file operations bypassed the
   repository's one-way boundary that permits them only in
   `SecureFileTree.swift`.
2. Task 3 kept strict full-plist validation, but the new legacy-service
   recognition dictionary plus the name and repeated calls of
   `expectedProgramArguments` raised the normalized `ProgramArguments` anchor
   count in `ServiceManager.swift` from one to six. The detector's synthetic
   second-occurrence test then observed seven rather than two.

## RED evidence

The two exact policy tests were run on HEAD `07f1cba` before production edits:

```text
Ran 2 tests in 0.302s
FAILED (failures=2)
```

The violations named all five direct POSIX capabilities in
`SetupCoordinator.swift` and reported `ProgramArguments` count 6. After adding
the SecureFileTree tests first, their focused compile failed only because
`SecureFileTree` had no `captureFileSnapshot` or `restoreFileSnapshot` member.
The focused ServiceManager suite remained green after adding a renamed
argument-key rejection variant; the ServiceManager defect was structural, and
its RED was the exact policy test rather than a runtime behavior change.

## Minimal implementation

- Added descriptor-bound snapshot capture and restore APIs to
  `SecureFileTree`. They retain single-component paths, no-follow traversal,
  required owner, regular-file and single-link checks, byte bounds, stable
  root/path bindings, atomic exclusive temporary publication, `0600` restored
  mode, file and directory `fsync`, final byte verification, and existing
  platform-specific unlink flags.
- `SetupCoordinator` now owns only enrollment transaction decisions and calls
  the secure abstraction. Its rollback/evidence/fail-closed lifecycle is
  unchanged.
- Renamed the ordinary ServiceManager argv builder so it no longer repeats the
  sensitive anchor. A single plist-arguments parser owns the exact key. Legacy
  validation derives that already-validated key from the full actual key set
  and still compares the complete dictionary recursively, including exact
  paths, argv, booleans, and absence of extra keys.

## GREEN and verification evidence

- Exact two policy tests: 2 run, OK.
- Full `tests.test_legacy_cleanup_policy`: 12 run, OK.
- SecureFileTree focused suite: `Secure file tree tests passed`.
- ServiceManager focused suite: `Service manager tests passed`.
- SetupCoordinator focused suite: `Setup coordinator tests passed`.
- LegacyInstallCleaner focused suite: `Legacy install cleaner tests passed`.
- Full app Swift typecheck: exit 0; only the pre-existing macOS 14
  `OnboardingView.onChange` deprecation warning remains.
- Full serial Python suite, captured completely in
  `.superpowers/sdd/task-6-policy-fix-python-suite.log`:

```text
Ran 231 tests in 99.949s
OK (skipped=1)
```

The one skip is the documented `release artifact gate not requested` class
skip. Two earlier overlapping runner captures were discarded because the
execution wrapper left them active and they shared a log; only their verified
task-owned process trees were terminated. The final result above was rerun
alone with exclusive log output.

## Files changed

- `src/app/SecureFileTree.swift`
- `src/app/SetupCoordinator.swift`
- `src/app/ServiceManager.swift`
- `tests/swift/SecureFileTreeTests.swift`
- `tests/swift/ServiceManagerTests.swift`

## Self-review and concerns

- No policy assertion, budget, detector, or allowlist was weakened.
- Existing current and legacy service plist validation remains fail closed;
  the new renamed-key variant proves a semantically similar key is rejected
  before launchctl mutation.
- Owner rollback still accepts a pre-existing safe regular file regardless of
  its prior permission bits, then restores it as `0600`, matching the previous
  transaction behavior.
- The absent-owner rollback retains the previous pathname-based final unlink
  model but now centralizes its validation and durability checks in
  SecureFileTree.
- The release archive was not rebuilt, as explicitly prohibited for this fix.

## Duplicate raw plist-key follow-up (2026-07-24)

**Status:** PASS. This isolated follow-up changes only `ServiceManager` raw
plist handling and the already-uncommitted ServiceManager duplicate-key tests.
No release, live app, launchctl, TCC, settings, user-data, or protection action
was performed.

### Root cause and fix

`PropertyListSerialization` accepts XML plist dictionaries with repeated
`<key>` entries and collapses them during dictionary coercion. A structural
`XMLParser` delegate now tracks direct `<key>` children for every `<dict>`
before coercion. A duplicate returns fail-closed (`needsRepair` for current
service status or `invalidTemplate` for legacy/template paths). It aborts the
parse once a duplicate is observed; valid binary plists retain their existing
support because an unparseable XML structure is not treated as a duplicate.

### TDD and verification evidence

- RED: the focused ServiceManager suite at `36c1e97` failed with
  `status accepted duplicate (name) plist key`.
- GREEN: focused ServiceManager suite passed, including current and legacy
  duplicate `ProgramArguments`/`Label` cases and their no-launchctl/no-plist
  mutation assertions, plus a binary plist preservation case.
- Full `tests.test_legacy_cleanup_policy`: 12 run, OK.
- Whole-app Swift typecheck: exit 0; it retains only the existing
  `OnboardingView.onChange` macOS 14 deprecation warning.

### Scope and concern

Exact recursive/type-safe plist comparison and legacy policy tests were left
unchanged. The detector treats only structurally parsed XML as observable;
malformed or binary data continues to be rejected or accepted by the existing
PropertyListSerialization path as appropriate.

## Secure snapshot restore race follow-up (2026-07-24)

**Status:** PASS. This isolated follow-up changes only `SecureFileTree`, its
focused tests, and this report. It did not rebuild a release or touch the live
app, launchctl, TCC, Settings, user data, or protection state.

### Root cause and fix

Snapshot restore validated the public destination and then directly renamed
over or unlinked that predictable pathname. A same-UID replacement in the
remaining check-to-mutation window could therefore be overwritten or deleted.

Present restores now move the current public destination to an exclusive,
unpredictable quarantine name, fsync the directory, and verify the moved inode
and file version. A mismatch is restored to the public name and reported as
`identityChanged`; the staged `0600` snapshot is published only with
`RENAME_EXCL`, then verified for identity, metadata, exact bytes, root binding,
and temporary-name removal before the verified quarantine is purged. Absent
restores now reuse the same existing quarantine, moved-inode verification,
restore-on-mismatch, unlink flags, and directory-fsync path as secure tree
deletion.

The two final-window callbacks are internal parameters with production defaults
of `nil`; they exist only to make the race deterministic in the focused suite.

### TDD and verification evidence

- RED at `6aa4565`: focused compilation failed only on the missing
  `beforeFinalPublish` and `beforeFinalRemoval` arguments.
- GREEN: `SecureFileTreeTests` passed, including present and absent
  last-window replacements; both assert `identityChanged` and exact attacker
  byte preservation.
- `SetupCoordinatorTests`: passed.
- Policy suites: 53 tests passed across legacy cleanup, open-source, and setup
  readiness policy.
- Whole-app Swift typecheck: exit 0; only the existing macOS 14
  `OnboardingView.onChange` deprecation warning remains.
- `git diff --check`: exit 0.

### Scope and concern

No SecureFileTree policy or allowlist was weakened. No-follow traversal,
current-owner regular single-link validation, size bounds, `0600` restore,
atomic publication, file and directory fsync, and fail-open coordinator
behavior remain in force. If a post-publication durability or verification
system call fails, the function reports failure and does not risk overwriting a
new public-path entrant; an already isolated old file may remain under its
unpredictable quarantine name for forensic recovery.
