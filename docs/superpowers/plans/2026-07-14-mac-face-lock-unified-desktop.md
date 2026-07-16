# Mac Face Lock Unified Desktop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the existing menu-bar status application into one native macOS app that provides both the menu-bar entry and the approved Liquid Glass desktop window while continuing to use exactly one Python Face Lock Agent.

**Architecture:** Keep the Python LaunchAgent as the only security executor. Add local JSON contracts for pause/resume control, structured activity history, and UI preferences; evolve the current Swift AppKit status process into a combined AppKit lifecycle plus SwiftUI window that reads those contracts. Preserve the existing UI LaunchAgent label so installation migrates in place.

**Tech Stack:** Python 3.9 standard library and `unittest`; Swift 6.3.2, SwiftUI, AppKit, Foundation; shell build/install scripts; macOS 26.5.1 host with application minimum version 12.0.

## Global Constraints

- There must remain exactly one Python Face Lock Agent process.
- `lock_on_camera_error=false` remains unchanged; camera failures must keep the Mac unlocked.
- `cooldown_seconds_after_lock=300` remains unchanged.
- Closing or quitting the UI must not stop the Python Agent.
- No cloud recognition, remote control, continuous camera preview, or automatic evidence thumbnails.
- The unified UI artifact is `dist/Mac Face Lock.app`; the UI LaunchAgent label remains `com.wuyi.mac-face-lock-status`.
- Appearance supports `system`, `light`, and `dark`; accents are exactly `oceanBlue`, `guardianGreen`, and `amethyst`.
- Theme accents never replace semantic green, amber, or red safety colors.
- The workspace currently contains many untracked project files. Every commit must stage exact paths; never use `git add .`.
- Preserve the two approved references under `docs/design-references/` and compare the built window against them during final QA.

## File Map

### Python core

- Create `control_store.py`: validated, atomic pause/resume control file contract.
- Create `activity_store.py`: append-only structured activity event contract.
- Modify `agent.py`: poll control state, expose paused state, and emit key activity events.
- Modify `tests/test_config.py`: convert the existing passive functions into runnable `unittest` cases.
- Create `tests/test_control_store.py`: control contract tests.
- Create `tests/test_activity_store.py`: activity contract tests.
- Create `tests/test_agent_control.py`: pause/resume and fail-open integration tests.

### Swift unified UI

- Create `src/app/Models.swift`: Codable state, activity, control, and UI preference models.
- Create `src/app/LocalJSONStore.swift`: defensive reads and atomic writes.
- Create `src/app/FaceLockStore.swift`: observable polling and pause/resume actions.
- Create `src/app/ThemeStore.swift`: system appearance and the three accent themes.
- Create `src/app/Views.swift`: sidebar, overview, activity, settings, and policy inspector.
- Create `src/app/DesktopWindowController.swift`: persistent desktop window lifecycle.
- Create `src/app/StatusMenuController.swift`: menu-bar title, status details, and actions.
- Create `src/app/AppDelegate.swift`: one lifecycle that wires the status item and window.
- Create `src/app/main.swift`: application entry point.
- Create `src/app/Info.plist`: unified application bundle metadata.
- Create `tests/swift/LocalStoreSmokeTests.swift`: executable Swift data-contract smoke test.
- Remove `src/statusbar/StatusBarApp.swift` only after the unified app builds and runs.

### Build and migration

- Modify `scripts/build-status-app.sh`: compile `src/app/*.swift` into `dist/Mac Face Lock.app` and verify its signature.
- Modify `launchd/com.wuyi.mac-face-lock-status.plist`: point to the unified executable.
- Modify `scripts/install-launchagent.sh`: migrate from the old UI app only after the new bundle verifies.
- Modify `scripts/uninstall-launchagent.sh`: keep both service labels but remove neither user data nor evidence.
- Modify `scripts/status.sh`: label the combined UI clearly and report whether its process is loaded.
- Modify `README.md`: document the fused menu-bar/desktop behavior and appearance settings.

---

### Task 1: Establish a runnable Python test baseline and the control-file contract

**Files:**
- Modify: `tests/test_config.py`
- Create: `tests/test_control_store.py`
- Create: `control_store.py`

**Interfaces:**
- Consumes: `state_store.now_iso() -> str`
- Produces: `ControlState`, `read_control(path, fallback)`, and `write_control(enabled, path)` for Task 3.

- [ ] **Step 1: Convert the configuration tests to `unittest`**

Replace `tests/test_config.py` with a `unittest.TestCase` containing the existing assertions and a plist test for both LaunchAgents. The executable entry point must be:

```python
if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the baseline tests**

Run:

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: the converted configuration tests pass without installing `pytest`.

- [ ] **Step 3: Write failing control-store tests**

Create `tests/test_control_store.py` with these cases:

```python
import json
import tempfile
import unittest
from pathlib import Path

from control_store import ControlState, read_control, write_control


class ControlStoreTests(unittest.TestCase):
    def test_missing_file_uses_enabled_default(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            self.assertEqual(read_control(path), ControlState(True, None))

    def test_round_trip_false(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            written = write_control(False, path)
            self.assertFalse(written.protection_enabled)
            self.assertEqual(read_control(path), written)
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(payload["schema_version"], 1)

    def test_invalid_file_uses_supplied_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            path.write_text("{broken", encoding="utf-8")
            fallback = ControlState(False, "previous")
            self.assertEqual(read_control(path, fallback), fallback)

    def test_non_boolean_enabled_uses_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.json"
            path.write_text('{"protection_enabled": "no"}', encoding="utf-8")
            fallback = ControlState(True, None)
            self.assertEqual(read_control(path, fallback), fallback)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 4: Run the control tests to verify failure**

Run:

```bash
.venv/bin/python -m unittest tests.test_control_store -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'control_store'`.

- [ ] **Step 5: Implement the control store**

Create `control_store.py` with a frozen `ControlState` dataclass. `read_control` must catch `OSError`, `json.JSONDecodeError`, invalid schema values, and non-boolean `protection_enabled`; it returns the supplied fallback without raising. `write_control` must create the parent, write UTF-8 JSON through `NamedTemporaryFile`, and publish with `os.replace`.

Use this complete implementation shape:

```python
from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path

from state_store import now_iso

CONTROL_PATH = Path(__file__).resolve().parent / "data" / "control.json"

@dataclass(frozen=True)
class ControlState:
    protection_enabled: bool
    updated_at: str | None

def read_control(
    path: Path = CONTROL_PATH,
    fallback: ControlState = ControlState(True, None),
) -> ControlState:
    if not path.exists():
        return fallback
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return fallback
    enabled = payload.get("protection_enabled")
    if not isinstance(enabled, bool):
        return fallback
    updated_at = payload.get("updated_at")
    if updated_at is not None and not isinstance(updated_at, str):
        return fallback
    return ControlState(enabled, updated_at)

def write_control(enabled: bool, path: Path = CONTROL_PATH) -> ControlState:
    state = ControlState(enabled, now_iso())
    payload = {
        "schema_version": 1,
        "protection_enabled": state.protection_enabled,
        "updated_at": state.updated_at,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent,
        prefix=f"{path.stem}.", suffix=".tmp", delete=False,
    ) as handle:
        tmp = Path(handle.name)
        json.dump(payload, handle, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    return state
```

The serialized object is exactly:

```python
payload = {
    "schema_version": 1,
    "protection_enabled": enabled,
    "updated_at": now_iso(),
}
```

- [ ] **Step 6: Run the full Python suite**

Run:

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: all configuration and control-store tests pass.

- [ ] **Step 7: Commit the control contract**

```bash
git add control_store.py tests/test_config.py tests/test_control_store.py
git commit -m "feat: add local protection control contract"
```

---

### Task 2: Add structured local activity history

**Files:**
- Create: `activity_store.py`
- Create: `tests/test_activity_store.py`

**Interfaces:**
- Consumes: `state_store.now_iso() -> str`
- Produces: `append_activity(event_type, title, detail, severity, metadata, path, event_id, timestamp) -> dict[str, Any]` for `agent.py` and `data/activity.jsonl` for Swift.

- [ ] **Step 1: Write failing activity-store tests**

Create tests for UTF-8 round-trip, default timestamp/UUID generation, explicit deterministic values, metadata preservation, and one JSON object per line. Use `tempfile.TemporaryDirectory` and `unittest.mock.patch("activity_store.os.fsync")` only if the host filesystem makes fsync timing visible.

The deterministic core assertion must be:

```python
event = append_activity(
    "owner_verified",
    "已确认本人",
    "达到本人识别阈值，继续使用",
    "success",
    {"owner_hits": 2, "stranger_hits": 0, "frames_checked": 2},
    path=path,
    event_id="event-1",
    timestamp="2026-07-14T13:48:00+08:00",
)
self.assertEqual(event["schema_version"], 1)
self.assertEqual(json.loads(path.read_text(encoding="utf-8")), event)
```

- [ ] **Step 2: Run the activity tests to verify failure**

Run:

```bash
.venv/bin/python -m unittest tests.test_activity_store -v
```

Expected: FAIL because `activity_store` does not exist.

- [ ] **Step 3: Implement append-only JSONL activity writing**

Create `activity_store.py` with this complete implementation shape:

```python
from __future__ import annotations

import json
import os
import threading
import uuid
from pathlib import Path
from typing import Any

from state_store import now_iso

ACTIVITY_PATH = Path(__file__).resolve().parent / "data" / "activity.jsonl"
_WRITE_LOCK = threading.Lock()

def append_activity(
    event_type: str,
    title: str,
    detail: str,
    severity: str,
    metadata: dict[str, Any] | None = None,
    *,
    path: Path = ACTIVITY_PATH,
    event_id: str | None = None,
    timestamp: str | None = None,
) -> dict[str, Any]:
    event = {
        "schema_version": 1,
        "id": event_id or str(uuid.uuid4()),
        "timestamp": timestamp or now_iso(),
        "type": event_type,
        "title": title,
        "detail": detail,
        "severity": severity,
        "metadata": metadata or {},
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
    with _WRITE_LOCK:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
            handle.flush()
            os.fsync(handle.fileno())
    return event
```

Build a dictionary containing `schema_version`, `id`, `timestamp`, `type`, `title`, `detail`, `severity`, and `metadata`. Serialize with `ensure_ascii=False`, append one newline under an in-process `threading.Lock`, flush, and call `os.fsync` before returning the same dictionary.

- [ ] **Step 4: Run activity and full Python tests**

Run:

```bash
.venv/bin/python -m unittest tests.test_activity_store -v
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: all tests pass and the temporary activity file has one event per line.

- [ ] **Step 5: Commit activity history**

```bash
git add activity_store.py tests/test_activity_store.py
git commit -m "feat: add structured face lock activity history"
```

---

### Task 3: Integrate pause/resume and key activity events into the Agent

**Files:**
- Modify: `agent.py:14-24,27-43,61-72,161-208,210-283,309-343,348-428`
- Create: `tests/test_agent_control.py`

**Interfaces:**
- Consumes: `ControlState`, `read_control`, `append_activity`.
- Produces: paused state JSON, activity events, and immediate pause/resume behavior for the unified UI.

- [ ] **Step 1: Write failing pause/resume tests**

Create `tests/test_agent_control.py`. Patch `agent.load_owner_encoding`, `agent.write_state`, and `agent.append_activity`. Instantiate `FaceLockAgent` with temporary `control_path` and `activity_path`. Verify:

1. Missing control defaults to enabled.
2. Changing the file to disabled sets `protection_enabled=False`, clears `armed`, writes `{status: paused, action: allow_paused, heartbeat: paused}`, and emits `protection_paused` once.
3. Re-reading unchanged disabled state does not duplicate the event.
4. Re-enabling writes active state, resets `last_activity_at`, and emits `protection_resumed` once.
5. `on_input` while paused never starts a verification thread.

- [ ] **Step 2: Run the Agent control tests to verify failure**

Run:

```bash
.venv/bin/python -m unittest tests.test_agent_control -v
```

Expected: FAIL because `FaceLockAgent` has no control-path constructor or `refresh_control_state` method.

- [ ] **Step 3: Add control dependencies and constructor state**

Add imports:

```python
from activity_store import ACTIVITY_PATH, append_activity
from control_store import CONTROL_PATH, ControlState, read_control
```

Change the constructor signature to:

```python
def __init__(
    self,
    config: dict[str, Any],
    *,
    control_path: Path = CONTROL_PATH,
    activity_path: Path = ACTIVITY_PATH,
) -> None:
```

Initialize `self.control_path`, `self.activity_path`, and `self.protection_enabled` from `read_control(control_path)`. Keep all existing cooldown fields unchanged.

- [ ] **Step 4: Implement transition-only control polling**

Add:

```python
def refresh_control_state(self) -> None:
    current = ControlState(self.protection_enabled, None)
    desired = read_control(self.control_path, current)
    if desired.protection_enabled == self.protection_enabled:
        return
    self.protection_enabled = desired.protection_enabled
    self.armed = False
    self.last_activity_at = time.monotonic()
    if self.protection_enabled:
        write_state({
            "status": "active",
            "mode": self.mode,
            "armed": False,
            "action": "wait_until_idle",
            "heartbeat": "active",
        })
        append_activity(
            "protection_resumed", "已恢复保护", "从正常使用状态重新开始计时",
            "info", path=self.activity_path,
        )
    else:
        write_state({
            "status": "paused",
            "mode": self.mode,
            "armed": False,
            "action": "allow_paused",
            "heartbeat": "paused",
        })
        append_activity(
            "protection_paused", "已暂停保护", "不会布防、验证或锁屏",
            "warning", path=self.activity_path,
        )
```

Call this once per `tick()` after listener health checking. If disabled, refresh the paused heartbeat at the existing active-state interval and return before presence-guard logic. Add an early return in `on_input` when disabled.

- [ ] **Step 5: Make initial state reflect a persisted pause**

In `run()`, use `status="paused"`, `action="allow_paused"`, and `heartbeat="paused"` when `self.protection_enabled` is false; otherwise preserve the current `running` startup state. Starting the service while paused must not emit a fake “resumed” event.

- [ ] **Step 6: Emit key events without logging heartbeats**

Call `append_activity` only at these existing transition points:

- Enter armed: `protection_armed`, title `进入布防`, severity `info`.
- Owner verified: `owner_verified`, title `已确认本人`, severity `success`, include hit/frame metadata.
- Non-owner/no-face/unknown result before lock: `verification_failed`, severity `warning`.
- Camera error fail-open: `camera_unavailable`, title `相机不可用，已保持解锁`, severity `warning`.
- Lock completed: `screen_locked`, title `已触发锁屏`, severity `critical`, include reason.
- Final evidence canceled a lock: `owner_verified`, detail `最终照片确认本人，已取消锁屏`.

Do not append events from active or armed heartbeat writes.

- [ ] **Step 7: Run focused and full tests**

Run:

```bash
.venv/bin/python -m unittest tests.test_agent_control -v
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: all tests pass. Explicitly assert the camera-error branch still writes `allow_camera_unavailable` and never calls `lock` when `lock_on_camera_error` is false.

- [ ] **Step 8: Commit Agent integration**

```bash
git add agent.py tests/test_agent_control.py
git commit -m "feat: connect face lock controls and activity events"
```

---

### Task 4: Build the Swift local data layer with an executable smoke test

**Files:**
- Create: `src/app/Models.swift`
- Create: `src/app/LocalJSONStore.swift`
- Create: `src/app/FaceLockStore.swift`
- Create: `tests/swift/LocalStoreSmokeTests.swift`

**Interfaces:**
- Consumes: `data/state.json`, `data/control.json`, and `data/activity.jsonl`.
- Produces: `FaceLockState`, `ActivityEvent`, `UIPreferences`, `LocalJSONStore`, and `FaceLockStore` for the UI controllers and views.

- [ ] **Step 1: Define Codable models**

Create models with these exact public types:

```swift
struct FaceLockState: Codable, Equatable {
    var status: String
    var mode: String?
    var armed: Bool
    var action: String?
    var heartbeat: String?
    var updatedAt: String?
    var systemIdleSeconds: Double?
    var lastDecision: String?
    var lastReason: String?
    var ownerHits: Int?
    var strangerHits: Int?
    var noFaceHits: Int?
    var framesChecked: Int?
    var lockReason: String?

    static let missing = FaceLockState(status: "missing", armed: false)
}

struct ActivityMetadata: Codable, Equatable {
    var ownerHits: Int?
    var strangerHits: Int?
    var noFaceHits: Int?
    var framesChecked: Int?
    var reason: String?
}

struct ActivityEvent: Codable, Identifiable, Equatable {
    var schemaVersion: Int
    var id: String
    var timestamp: String
    var type: String
    var title: String
    var detail: String
    var severity: String
    var metadata: ActivityMetadata
}

struct ControlFile: Codable, Equatable {
    var schemaVersion: Int = 1
    var protectionEnabled: Bool
    var updatedAt: String
}

enum AppearanceMode: String, Codable, CaseIterable { case system, light, dark }
enum AccentTheme: String, Codable, CaseIterable { case oceanBlue, guardianGreen, amethyst }

struct UIPreferences: Codable, Equatable {
    var schemaVersion: Int = 1
    var appearance: AppearanceMode = .system
    var accent: AccentTheme = .oceanBlue
}
```

Give convenience initializers default `nil` for every optional field so `FaceLockState.missing` compiles. Configure all JSON encoders/decoders with `.convertToSnakeCase` and `.convertFromSnakeCase`.

- [ ] **Step 2: Write the failing Swift smoke test**

Create a standalone `@main` executable that:

- Creates a temporary project root.
- Writes a valid `state.json` and one valid plus one malformed activity line.
- Verifies state decoding, malformed-line skipping, newest-first ordering, and the 200-event limit.
- Writes control and preferences, re-reads them, and verifies exact round-trip values.
- Prints `Swift local store smoke tests passed` and exits 0.

- [ ] **Step 3: Compile the smoke test to verify failure**

Run:

```bash
xcrun swiftc -parse-as-library \
  src/app/Models.swift src/app/LocalJSONStore.swift \
  tests/swift/LocalStoreSmokeTests.swift \
  -o /tmp/mac-face-lock-store-tests
```

Expected: FAIL because the source files do not yet exist or their methods are missing.

- [ ] **Step 4: Implement defensive local JSON storage**

`LocalJSONStore` must expose:

```swift
final class LocalJSONStore {
    let projectURL: URL
    init(projectURL: URL)
    func readState() -> FaceLockState
    func readActivities(limit: Int = 200) -> [ActivityEvent]
    func readControl() -> ControlFile
    func writeControl(enabled: Bool) throws -> ControlFile
    func readPreferences() -> UIPreferences
    func writePreferences(_ preferences: UIPreferences) throws
}
```

Use `Data.write(to:options:.atomic)` for control and preferences. Missing or malformed state returns `.missing`; missing control returns enabled; missing or unknown preferences return defaults; malformed JSONL lines are skipped independently.

- [ ] **Step 5: Implement the observable face-lock store**

`@MainActor final class FaceLockStore: ObservableObject` publishes `state`, `activities`, `protectionEnabled`, and `lastError`. It owns a two-second timer, refreshes all readable files, and exposes:

```swift
func startPolling()
func stopPolling()
func refresh()
func setProtectionEnabled(_ enabled: Bool)
```

The setter must write first, then update published UI state; on failure it must leave the previous state unchanged and set a user-readable Chinese error.

- [ ] **Step 6: Run the Swift smoke test**

Run the compile command from Step 3, then:

```bash
/tmp/mac-face-lock-store-tests
```

Expected output: `Swift local store smoke tests passed`.

- [ ] **Step 7: Commit the Swift data layer**

```bash
git add src/app/Models.swift src/app/LocalJSONStore.swift src/app/FaceLockStore.swift tests/swift/LocalStoreSmokeTests.swift
git commit -m "feat: add unified app local data stores"
```

---

### Task 5: Implement system appearance, three accent themes, and shared presentation mapping

**Files:**
- Create: `src/app/ThemeStore.swift`
- Create: `src/app/Presentation.swift`

**Interfaces:**
- Consumes: `UIPreferences`, `LocalJSONStore`, and raw `FaceLockState`.
- Produces: `ThemeStore`, semantic theme colors, status titles, details, and SF Symbol names for both the window and menu bar.

- [ ] **Step 1: Implement theme persistence and color mapping**

`@MainActor final class ThemeStore: ObservableObject` must publish one `UIPreferences`, save changes through `LocalJSONStore`, and expose:

```swift
var preferredColorScheme: ColorScheme?
var accentColor: Color
func setAppearance(_ appearance: AppearanceMode)
func setAccent(_ accent: AccentTheme)
```

Mappings:

- `system -> nil`, `light -> .light`, `dark -> .dark`
- `oceanBlue -> Color(red: 0.20, green: 0.48, blue: 0.96)`
- `guardianGreen -> Color(red: 0.28, green: 0.67, blue: 0.32)`
- `amethyst -> Color(red: 0.56, green: 0.32, blue: 0.86)`

Theme color may tint navigation, buttons, and selection. Status-safe remains `Color(nsColor: .systemGreen)`, warning remains `.systemOrange`, and critical remains `.systemRed`.

- [ ] **Step 2: Implement one shared state presentation mapping**

Create `StatusPresentation` with these outputs:

```swift
struct StatusPresentation {
    let menuTitle: String
    let headline: String
    let detail: String
    let symbol: String
    let severity: StatusSeverity
}

enum StatusSeverity { case safe, neutral, warning, critical }
func present(_ state: FaceLockState) -> StatusPresentation
```

Map at least `missing`, `paused`, `running`, `active`, `armed`, `verifying`, `verified`, `camera_unavailable`, `locking`, `locked`, `event_notify_error`, and `input_listener_error`. `camera_unavailable` copy is exactly `相机不可用，已保持解锁`.

- [ ] **Step 3: Compile the data and presentation layer**

Run:

```bash
xcrun swiftc -parse-as-library -typecheck src/app/Models.swift src/app/LocalJSONStore.swift src/app/FaceLockStore.swift src/app/ThemeStore.swift src/app/Presentation.swift
```

Expected: exit 0 with no diagnostics.

- [ ] **Step 4: Commit theme and presentation**

```bash
git add src/app/ThemeStore.swift src/app/Presentation.swift
git commit -m "feat: add adaptive glass theme presentation"
```

---

### Task 6: Build the unified menu-bar and desktop application shell

**Files:**
- Create: `src/app/AppDelegate.swift`
- Create: `src/app/DesktopWindowController.swift`
- Create: `src/app/StatusMenuController.swift`
- Create: `src/app/main.swift`
- Create: `src/app/Views.swift` with a minimal but complete first RootView

**Interfaces:**
- Consumes: `FaceLockStore`, `ThemeStore`, `StatusPresentation`.
- Produces: one accessory application process with a status item and persistent desktop window.

- [ ] **Step 1: Implement the persistent desktop window controller**

First create a complete `RootView` in `Views.swift` that accepts `FaceLockStore` and `ThemeStore`, shows the shared status headline and the pause/resume button on a system material, and applies the selected tint and preferred color scheme. Then create one `NSWindow` with style masks `.titled`, `.closable`, `.miniaturizable`, and `.resizable`; initial size `1180 x 760`, minimum size `900 x 620`, transparent titlebar, full-size content view, and `isReleasedWhenClosed=false`. Host `RootView` using `NSHostingController`. `show()` centers only on first open, calls `makeKeyAndOrderFront`, and activates the app without creating a second window.

- [ ] **Step 2: Implement the status menu controller**

Create `NSStatusItem.variableLength` and rebuild its `NSMenu` from the shared store. Menu order:

1. Disabled current state row.
2. Disabled current action and updated-time rows.
3. Separator.
4. `打开控制中心`.
5. `暂停保护` or `恢复保护`.
6. `刷新状态`.
7. `打开证据目录`.
8. `打开日志`.
9. Separator.
10. `退出界面`.

The toggle calls `FaceLockStore.setProtectionEnabled`. The quit action terminates only the Swift UI. Menu title uses `StatusPresentation.menuTitle` and includes `脸锁:暂停` for paused state.

- [ ] **Step 3: Implement application lifecycle wiring**

`AppDelegate` must:

- Resolve the project root from the first command-line argument, with the existing absolute path as fallback.
- Call `NSApp.setActivationPolicy(.accessory)`.
- Construct exactly one `LocalJSONStore`, `FaceLockStore`, and `ThemeStore`.
- Construct `DesktopWindowController` and `StatusMenuController` with the same stores.
- Start polling and refresh the menu every two seconds.
- Show the desktop window on `applicationShouldHandleReopen`.
- Stop timers in `applicationWillTerminate` without touching the Python Agent.

`main.swift` keeps the current AppKit entry pattern:

```swift
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 4: Type-check the shell**

Run:

```bash
xcrun swiftc -parse-as-library -typecheck src/app/*.swift -framework AppKit -framework SwiftUI
```

Expected: exit 0 with no diagnostics. Task 7 expands the already working `RootView`; it does not repair an intentionally broken shell.

- [ ] **Step 5: Commit the application shell**

```bash
git add src/app/AppDelegate.swift src/app/DesktopWindowController.swift src/app/StatusMenuController.swift src/app/main.swift src/app/Views.swift
git commit -m "feat: unify status menu and desktop lifecycle"
```

---

### Task 7: Implement the approved Liquid Glass overview, activity, and appearance screens

**Files:**
- Modify: `src/app/Views.swift`

**Interfaces:**
- Consumes: `FaceLockStore`, `ThemeStore`, the two approved PNG references, and `StatusPresentation`.
- Produces: `RootView` and all visible desktop interactions.

- [ ] **Step 1: Implement the root three-column layout**

`RootView` owns `@State private var selection: AppSection = .overview`. Use a manual `HStack(spacing: 0)` so macOS 12 remains supported. Layout widths:

- Sidebar: fixed `210` points.
- Main content: minimum `520` points and flexible.
- Policy inspector: fixed `300` points when total width is at least `1050`; otherwise hide it.

Use `.ultraThinMaterial` for the sidebar, `.regularMaterial` for timeline surfaces, fine white/black opacity separators, and no decorative wallpaper image. The window backdrop uses the selected accent as a low-opacity radial/linear tint so system transparency remains legible.

- [ ] **Step 2: Implement navigation and overview**

Define exactly three sections: `保护`, `记录`, and `设置` with symbols `checkmark.shield`, `clock`, and `gearshape`.

Overview content must include:

- Semantic shield and shared status headline.
- Primary `暂停保护` or `恢复保护` button.
- `今天` activity timeline using the newest events from `FaceLockStore.activities`.
- Empty fallback derived from current `state.json` rather than fake sample events.
- `查看全部记录` navigation action.
- User-readable write error under the primary action when control write fails.

- [ ] **Step 3: Implement policy inspector and records**

Policy inspector copy is fixed:

```text
当前策略
1  空闲 60 秒
2  输入触发验证
3  非本人锁屏
相机不可用时保持解锁
锁屏后冷却 5 分钟
```

Records show newest-first rows with semantic symbol/color, localized time, title, detail, and metadata counts. Include `打开证据目录` and `打开日志` buttons; never decode or render evidence images.

- [ ] **Step 4: Implement appearance settings**

Match the approved settings reference:

- Segmented appearance picker with `跟随系统`, `浅色`, `深色`.
- Exactly three accent choices labeled `深海蓝`, `守护绿`, `紫晶`.
- Live preview containing semantic-green `已开启 · 正常使用中` and an accent-tinted `暂停保护` button.
- Copy `仅改变强调色与玻璃染色，不影响安全状态颜色`.

Apply `.preferredColorScheme(themeStore.preferredColorScheme)` at the root and `.tint(themeStore.accentColor)` to the content tree.

- [ ] **Step 5: Type-check the complete Swift app**

Run:

```bash
xcrun swiftc -parse-as-library -typecheck src/app/*.swift -framework AppKit -framework SwiftUI
```

Expected: exit 0 with no diagnostics.

- [ ] **Step 6: Commit the desktop views**

```bash
git add src/app/Views.swift
git commit -m "feat: add unified glass desktop views"
```

---

### Task 8: Package the unified app and migrate the UI LaunchAgent

**Files:**
- Create: `src/app/Info.plist`
- Modify: `scripts/build-status-app.sh`
- Modify: `launchd/com.wuyi.mac-face-lock-status.plist:9-13`
- Modify: `scripts/install-launchagent.sh:40-51`
- Modify: `scripts/uninstall-launchagent.sh`
- Modify: `scripts/status.sh`
- Delete: `src/statusbar/StatusBarApp.swift`

**Interfaces:**
- Consumes: all `src/app/*.swift` source files.
- Produces: signed `dist/Mac Face Lock.app`, executable `MacFaceLock`, and an in-place launch migration.

- [ ] **Step 1: Create bundle metadata**

`Info.plist` values:

```xml
<key>CFBundleName</key><string>Mac Face Lock</string>
<key>CFBundleDisplayName</key><string>Mac Face Lock</string>
<key>CFBundleIdentifier</key><string>com.wuyi.mac-face-lock.app</string>
<key>CFBundleVersion</key><string>1.1.0</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleExecutable</key><string>MacFaceLock</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
```

- [ ] **Step 2: Rewrite the UI build script**

Build in `dist/.Mac Face Lock.app.building`, copy `Info.plist`, compile every `src/app/*.swift` with AppKit and SwiftUI, sign ad hoc, verify with `codesign --verify --deep --strict`, then atomically replace `dist/Mac Face Lock.app`. Print the final application path. Do not remove the old status app inside the build script.

- [ ] **Step 3: Verify a first unified build**

Run:

```bash
scripts/build-status-app.sh
plutil -lint "dist/Mac Face Lock.app/Contents/Info.plist"
codesign --verify --deep --strict "dist/Mac Face Lock.app"
file "dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock"
```

Expected: valid plist, valid ad-hoc signature, and an arm64 Mach-O executable.

- [ ] **Step 4: Update launch and installer migration paths**

Change the UI LaunchAgent executable to:

```text
$PROJECT_DIR/dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock
```

Keep the project-root argument and label unchanged. Installer order is: validate prerequisites, build Python app, build unified UI, verify bundle, copy both plists, reload Python Agent, reload UI, verify both labels with `launchctl print`, then remove `dist/Mac Face Lock Status.app` only after the new UI is running.

- [ ] **Step 5: Update status and uninstall scripts**

Use user-facing label `融合界面` in `scripts/status.sh`. Uninstall continues to unload both labels and remove their plist copies but must not remove `data/control.json`, `data/activity.jsonl`, `data/ui-preferences.json`, evidence, or owner face data.

- [ ] **Step 6: Remove the superseded one-file status app**

Delete `src/statusbar/StatusBarApp.swift` only after Step 3 passes. Keep no second UI executable in the build graph.

- [ ] **Step 7: Commit packaging and migration**

```bash
git add src/app/Info.plist scripts/build-status-app.sh launchd/com.wuyi.mac-face-lock-status.plist scripts/install-launchagent.sh scripts/uninstall-launchagent.sh scripts/status.sh
git rm src/statusbar/StatusBarApp.swift
git commit -m "feat: package unified Mac Face Lock app"
```

---

### Task 9: Document the fused workflow and run complete automated verification

**Files:**
- Modify: `README.md`
- Modify: `tests/test_config.py`

**Interfaces:**
- Consumes: final scripts, bundle paths, and LaunchAgent labels.
- Produces: durable setup instructions and automated migration-path assertions.

- [ ] **Step 1: Extend configuration tests**

Assert the UI plist executable contains `dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock`, both labels retain `RunAtLoad=true` and `KeepAlive=true`, `lock_on_camera_error` is false, and both cooldown values remain 300 or greater.

- [ ] **Step 2: Update the README**

Document:

- One Python Agent plus one combined menu-bar/desktop UI.
- How to open the control center from the menu bar.
- Pause/resume semantics and the visible paused warning.
- Activity history location and its local-only nature.
- System appearance and the three accent themes.
- Build, install, status, and uninstall commands.
- The invariant that camera failure keeps the Mac unlocked.

- [ ] **Step 3: Run all automated checks**

Run:

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
xcrun swiftc -parse-as-library \
  src/app/Models.swift src/app/LocalJSONStore.swift \
  tests/swift/LocalStoreSmokeTests.swift \
  -o /tmp/mac-face-lock-store-tests
/tmp/mac-face-lock-store-tests
scripts/build-app.sh
scripts/build-status-app.sh
plutil -lint launchd/com.wuyi.mac-face-lock-agent.plist launchd/com.wuyi.mac-face-lock-status.plist
codesign --verify --deep --strict "dist/Mac Face Lock Agent.app"
codesign --verify --deep --strict "dist/Mac Face Lock.app"
```

Expected: every command exits 0.

- [ ] **Step 4: Commit documentation and automated acceptance**

```bash
git add README.md tests/test_config.py
git commit -m "docs: explain unified Mac Face Lock workflow"
```

---

### Task 10: Install, open, and visually verify the real macOS application

**Files:**
- Runtime artifacts only: `$HOME/Library/LaunchAgents/*.plist`, `dist/*.app`, `data/*.json`, and `logs/*`
- No source edits unless verification identifies a concrete defect.

**Interfaces:**
- Consumes: signed Agent and unified UI bundles.
- Produces: a running, visually verified fused client with no duplicate Agent.

- [ ] **Step 1: Capture the pre-migration runtime truth**

Run `scripts/status.sh`, record both launch labels, current `data/state.json`, and current process list. Do not print full `launchctl` environment blocks.

- [ ] **Step 2: Install the fused version**

Run:

```bash
scripts/install-launchagent.sh
```

Expected: both `com.wuyi.mac-face-lock-agent` and `com.wuyi.mac-face-lock-status` load successfully.

- [ ] **Step 3: Prove there is only one security Agent**

Use `launchctl print`, the scrubbed status script, and `pgrep -fl 'MacFaceLockAgent|agent.py|MacFaceLock'`. Confirm one Python security process and one unified UI process; the old `MacFaceLockStatus` process must be absent.

- [ ] **Step 4: Verify pause and resume without risking an accidental lock**

Open the control center, pause protection, confirm desktop window, menu bar, and `state.json` all show paused. Move the mouse and type while paused; confirm no verification or lock event appears. Resume, confirm active state and a fresh idle timer. Do not force a stranger/no-face lock during this step.

- [ ] **Step 5: Verify themes and persistence**

Switch system/light/dark and each of the three accent themes. Quit only the UI, let the UI LaunchAgent restart it, and confirm `data/ui-preferences.json` restores the selected values. Verify semantic safe/warning colors remain unchanged.

- [ ] **Step 6: Perform visual comparison against both references**

Open `dist/Mac Face Lock.app`, capture the overview and settings screens at the same approximately `1180 x 760` window size, and compare each built screenshot alongside its corresponding file in `docs/design-references/`. Check glass depth, sidebar width, timeline density, policy inspector, typography, spacing, truncation, titlebar, and three-theme controls. Fix visible discrepancies and repeat the comparison until no major mismatch remains.

- [ ] **Step 7: Verify close-window and relaunch behavior**

Close the desktop window and confirm the menu-bar item and Python Agent remain. Use `打开控制中心` to reopen the same window. Quit the UI and confirm launchd restarts only the UI while the Agent PID remains stable.

- [ ] **Step 8: Run final safety regression**

Run the invalid-camera diagnostic path with `camera_index=999` in an isolated/manual test and confirm `action=allow_camera_unavailable` without locking. Restore the real camera configuration and restart the Agent. Confirm `cooldown_seconds_after_lock` remains 300.

- [ ] **Step 9: Run the final status checklist**

Run `scripts/status.sh` and verify process truth, state freshness, UI label health, logs, and event-layer queue separately. Report any remaining mismatch plainly; do not call the build complete from compiler output alone.

- [ ] **Step 10: Commit only defect fixes discovered during QA**

If QA required source changes, rerun all Task 9 commands and commit exact paths with a message describing the visible or runtime defect. If no source change was required, do not create an empty commit.
