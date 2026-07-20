# Mac Face Lock Control Center Click and Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Mac Face Lock control center reliably clickable as a normal macOS desktop application and ship a recognizable blue face-and-shield application icon.

**Architecture:** Keep the existing AppKit lifecycle and SwiftUI screens, but make the visible control center a regular application and move decorative card borders into one non-hit-testing SwiftUI component. Generate the icon deterministically from project-owned geometry, store the final `AppIcon.icns` in source, and copy it into every built control-center bundle.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Core Graphics, Python `unittest`, shell build scripts, `sips`, `iconutil`, ad-hoc macOS code signing.

## Global Constraints

- Target Apple Silicon and macOS 12.0 or newer.
- Do not delete or migrate existing face enrollment, settings, evidence, or activity data.
- Do not change face-recognition algorithms, thresholds, permission requirements, or the Agent Bundle ID.
- The prebuilt release must remain usable without Codex, Python, Xcode, Terminal, or a source checkout.
- The icon must contain no text, photos, third-party branding, or online build dependency.
- A safety-test failure must remain fail-closed for enabling protection and must never trigger a test lock.

---

## File Structure

- `src/app/DecorativeCardBorder.swift`: one reusable decorative border that never participates in hit testing.
- `src/app/AppDelegate.swift`: regular desktop activation policy.
- `src/app/Info.plist`: desktop-app identity and `AppIcon` declaration.
- `src/app/OnboardingView.swift`: uses the noninteractive border for onboarding cards.
- `src/app/SettingsView.swift`: uses the same border for interactive settings cards.
- `scripts/generate-app-icon.swift`: deterministic 1024px master artwork renderer.
- `scripts/generate-app-icon.sh`: produces a complete macOS iconset and `AppIcon.icns`.
- `src/app/AppIcon.icns`: generated application icon consumed by the build.
- `scripts/build-status-app.sh`: copies `AppIcon.icns` into the application resources.
- `tests/test_packaging.py`: regression contracts for activation, pointer hit testing, icon metadata, and icon packaging.
- `docs/session-handoff.md`: final build hash, size, test counts, and local acceptance result.

### Task 1: Make the control center reliably interactive

**Files:**
- Create: `src/app/DecorativeCardBorder.swift`
- Modify: `src/app/AppDelegate.swift`
- Modify: `src/app/Info.plist`
- Modify: `src/app/OnboardingView.swift`
- Modify: `src/app/SettingsView.swift`
- Test: `tests/test_packaging.py`

**Interfaces:**
- Consumes: existing `OnboardingCard`, `SettingsSection`, `NSApplication`, and SwiftUI `overlay` APIs.
- Produces: `DecorativeCardBorder(cornerRadius:color:lineWidth:)`, a visual-only SwiftUI view with hit testing disabled.

- [ ] **Step 1: Add the failing pointer-event regression test**

Add this test to `UnifiedPackagingTests`:

```python
def test_interactive_cards_use_non_hit_testing_decorative_borders(self) -> None:
    border_path = PROJECT_DIR / "src" / "app" / "DecorativeCardBorder.swift"
    self.assertTrue(border_path.is_file())
    border = border_path.read_text(encoding="utf-8")
    onboarding = (
        PROJECT_DIR / "src" / "app" / "OnboardingView.swift"
    ).read_text(encoding="utf-8")
    settings = (
        PROJECT_DIR / "src" / "app" / "SettingsView.swift"
    ).read_text(encoding="utf-8")

    self.assertIn(".allowsHitTesting(false)", border)
    self.assertIn("DecorativeCardBorder(", onboarding)
    self.assertIn("DecorativeCardBorder(", settings)
```

Keep the existing `test_control_center_runs_as_an_activatable_desktop_application` regression, which requires `LSUIElement == False` and `.regular` activation.

- [ ] **Step 2: Run the targeted tests and verify RED**

Run:

```bash
python3 -m unittest \
  tests.test_packaging.UnifiedPackagingTests.test_control_center_runs_as_an_activatable_desktop_application \
  tests.test_packaging.UnifiedPackagingTests.test_interactive_cards_use_non_hit_testing_decorative_borders
```

Expected: the activation test passes from the already diagnosed change, while the new card-border test fails because `DecorativeCardBorder.swift` does not exist.

- [ ] **Step 3: Add the minimal noninteractive border**

Create `src/app/DecorativeCardBorder.swift`:

```swift
import SwiftUI

struct DecorativeCardBorder: View {
    let cornerRadius: CGFloat
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(color, lineWidth: lineWidth)
            .allowsHitTesting(false)
    }
}
```

In `OnboardingCard`, replace the decorative overlay body with:

```swift
.overlay {
    DecorativeCardBorder(
        cornerRadius: 20,
        color: Color.white.opacity(0.12),
        lineWidth: 1
    )
}
```

In `SettingsSection`, replace the decorative overlay body with:

```swift
.overlay {
    DecorativeCardBorder(
        cornerRadius: 18,
        color: Color.white.opacity(0.10),
        lineWidth: 1
    )
}
```

Keep the diagnosed activation changes:

```swift
NSApp.setActivationPolicy(.regular)
```

and:

```xml
<key>LSUIElement</key>
<false/>
```

- [ ] **Step 4: Run the targeted tests and Swift typecheck**

Run:

```bash
python3 -m unittest \
  tests.test_packaging.UnifiedPackagingTests.test_control_center_runs_as_an_activatable_desktop_application \
  tests.test_packaging.UnifiedPackagingTests.test_interactive_cards_use_non_hit_testing_decorative_borders

xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework ApplicationServices \
  -framework CoreGraphics
```

Expected: both Python tests pass and Swift typechecking exits with status 0.

- [ ] **Step 5: Commit the interaction fix**

```bash
git add \
  src/app/DecorativeCardBorder.swift \
  src/app/AppDelegate.swift \
  src/app/Info.plist \
  src/app/OnboardingView.swift \
  src/app/SettingsView.swift \
  tests/test_packaging.py
git commit -m "fix: make control center reliably interactive"
```

### Task 2: Generate and package the application icon

**Files:**
- Create: `scripts/generate-app-icon.swift`
- Create: `scripts/generate-app-icon.sh`
- Create: `src/app/AppIcon.icns`
- Modify: `src/app/Info.plist`
- Modify: `scripts/build-status-app.sh`
- Test: `tests/test_packaging.py`

**Interfaces:**
- Consumes: local AppKit drawing, `sips`, and `iconutil`.
- Produces: `src/app/AppIcon.icns`, declared as `CFBundleIconFile=AppIcon` and copied to `Contents/Resources/AppIcon.icns`.

- [ ] **Step 1: Add the failing icon packaging regression**

Add this test to `UnifiedPackagingTests`:

```python
def test_control_center_packages_the_project_owned_icon(self) -> None:
    info_path = PROJECT_DIR / "src" / "app" / "Info.plist"
    icon_path = PROJECT_DIR / "src" / "app" / "AppIcon.icns"
    builder = UI_BUILD_SCRIPT.read_text(encoding="utf-8")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)

    self.assertEqual(info["CFBundleIconFile"], "AppIcon")
    self.assertTrue(icon_path.is_file())
    self.assertGreater(icon_path.stat().st_size, 10_000)
    self.assertIn(
        'cp "$ROOT_DIR/src/app/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"',
        builder,
    )

    with tempfile.TemporaryDirectory() as directory:
        subprocess.run(
            [
                "iconutil",
                "-c",
                "iconset",
                "-o",
                str(Path(directory) / "AppIcon.iconset"),
                str(icon_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
```

- [ ] **Step 2: Run the icon regression and verify RED**

Run:

```bash
python3 -m unittest \
  tests.test_packaging.UnifiedPackagingTests.test_control_center_packages_the_project_owned_icon
```

Expected: FAIL because `CFBundleIconFile` and `src/app/AppIcon.icns` are absent.

- [ ] **Step 3: Add the deterministic master artwork renderer**

Create `scripts/generate-app-icon.swift`:

```swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-app-icon.swift OUTPUT.png\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)
image.lockFocus()

NSGraphicsContext.current?.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(origin: .zero, size: canvas).fill()

let tile = NSBezierPath(
    roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880),
    xRadius: 210,
    yRadius: 210
)
NSGradient(
    starting: NSColor(calibratedRed: 0.96, green: 0.99, blue: 1.00, alpha: 1),
    ending: NSColor(calibratedRed: 0.78, green: 0.90, blue: 1.00, alpha: 1)
)!.draw(in: tile, angle: -55)

func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

let blue = NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.96, alpha: 1)
let navy = NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.62, alpha: 1)

for (start, corner, end) in [
    (NSPoint(x: 250, y: 650), NSPoint(x: 250, y: 770), NSPoint(x: 370, y: 770)),
    (NSPoint(x: 654, y: 770), NSPoint(x: 774, y: 770), NSPoint(x: 774, y: 650)),
    (NSPoint(x: 250, y: 374), NSPoint(x: 250, y: 254), NSPoint(x: 370, y: 254)),
    (NSPoint(x: 654, y: 254), NSPoint(x: 774, y: 254), NSPoint(x: 774, y: 374)),
] {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: corner)
    path.line(to: end)
    stroke(path, color: blue, width: 52)
}

blue.setFill()
NSBezierPath(ovalIn: NSRect(x: 386, y: 542, width: 54, height: 70)).fill()
NSBezierPath(ovalIn: NSRect(x: 584, y: 542, width: 54, height: 70)).fill()

let smile = NSBezierPath()
smile.move(to: NSPoint(x: 402, y: 472))
smile.curve(
    to: NSPoint(x: 622, y: 472),
    controlPoint1: NSPoint(x: 450, y: 394),
    controlPoint2: NSPoint(x: 574, y: 394)
)
stroke(smile, color: blue, width: 40)

let shield = NSBezierPath()
shield.move(to: NSPoint(x: 640, y: 410))
shield.line(to: NSPoint(x: 790, y: 458))
shield.line(to: NSPoint(x: 790, y: 330))
shield.curve(
    to: NSPoint(x: 640, y: 206),
    controlPoint1: NSPoint(x: 790, y: 258),
    controlPoint2: NSPoint(x: 720, y: 222)
)
shield.curve(
    to: NSPoint(x: 490, y: 330),
    controlPoint1: NSPoint(x: 560, y: 222),
    controlPoint2: NSPoint(x: 490, y: 258)
)
shield.line(to: NSPoint(x: 490, y: 458))
shield.close()
navy.setFill()
shield.fill()

let check = NSBezierPath()
check.move(to: NSPoint(x: 562, y: 334))
check.line(to: NSPoint(x: 620, y: 278))
check.line(to: NSPoint(x: 724, y: 382))
stroke(check, color: .white, width: 34)

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("unable to render PNG\n", stderr)
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
```

- [ ] **Step 4: Add the iconset generator**

Create `scripts/generate-app-icon.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-face-lock-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

MASTER="$WORK_DIR/AppIcon-1024.png"
ICONSET="$WORK_DIR/AppIcon.iconset"
OUTPUT="$ROOT_DIR/src/app/AppIcon.icns"
mkdir -p "$ICONSET"

xcrun swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$MASTER"

render() {
  local pixels="$1"
  local name="$2"
  sips -z "$pixels" "$pixels" "$MASTER" \
    --out "$ICONSET/$name" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns -o "$OUTPUT" "$ICONSET"
echo "$OUTPUT"
```

Make it executable and generate the committed asset:

```bash
chmod +x scripts/generate-app-icon.sh
scripts/generate-app-icon.sh
```

Expected: `src/app/AppIcon.icns` exists and is larger than 10 KB.

- [ ] **Step 5: Declare and copy the icon**

Add to `src/app/Info.plist`:

```xml
<key>CFBundleIconFile</key>
<string>AppIcon</string>
```

After the existing Info.plist copy in `scripts/build-status-app.sh`, add:

```bash
cp "$ROOT_DIR/src/app/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
```

- [ ] **Step 6: Run the icon regression, build, and inspect**

Run:

```bash
python3 -m unittest \
  tests.test_packaging.UnifiedPackagingTests.test_control_center_packages_the_project_owned_icon
scripts/build-status-app.sh
plutil -p "dist/Mac Face Lock.app/Contents/Info.plist"
codesign --verify --deep --strict "dist/Mac Face Lock.app"
```

Expected: the test passes, plist output contains `"CFBundleIconFile" => "AppIcon"`, and signature verification exits with status 0.

- [ ] **Step 7: Commit the icon**

```bash
git add \
  scripts/generate-app-icon.swift \
  scripts/generate-app-icon.sh \
  src/app/AppIcon.icns \
  src/app/Info.plist \
  scripts/build-status-app.sh \
  tests/test_packaging.py
git commit -m "feat: add Mac Face Lock application icon"
```

### Task 3: Rebuild and perform local release acceptance

**Files:**
- Modify: `docs/session-handoff.md`
- Generate: `dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip`
- Generate: `dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip.sha256`

**Interfaces:**
- Consumes: Task 1 interaction fix and Task 2 packaged icon.
- Produces: a verified local release ZIP plus recorded acceptance evidence.

- [ ] **Step 1: Run the full Python and application compile gates**

Run:

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v

xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework ApplicationServices \
  -framework CoreGraphics

git diff --check
```

Expected: every Python test passes apart from documented release-only skips, Swift typechecking exits 0, and `git diff --check` prints nothing.

- [ ] **Step 2: Build and verify the complete release**

Run:

```bash
scripts/build-release.sh
shasum -a 256 -c \
  dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip.sha256
scripts/manual-release-acceptance.sh
```

Expected: release-bundle tests pass, checksum reports `OK`, and manual preflight reports PASS.

- [ ] **Step 3: Install the rebuilt application without touching support data**

Stop only the control-center process, extract the ZIP, and atomically replace `/Applications/Mac Face Lock.app`. Do not remove:

```text
~/Library/Application Support/Mac Face Lock
```

After replacement, run:

```bash
codesign --verify --deep --strict "/Applications/Mac Face Lock.app"
plutil -p "/Applications/Mac Face Lock.app/Contents/Info.plist"
```

Expected: signature verification exits 0, `LSUIElement` is false, and `CFBundleIconFile` is `AppIcon`.

- [ ] **Step 4: Perform the user-visible acceptance**

With the user at the Mac:

1. Open Mac Face Lock from Dock.
2. Confirm the blue face-and-shield icon appears in Dock and Finder.
3. Single-click `运行安全测试`.
4. Confirm `正在执行不锁屏安全测试…` appears immediately.
5. Keep the user facing the camera for owner verification.
6. Confirm the safety test either advances to `完成并开启` or shows one exact recoverable permission/service error.
7. Confirm `owner_face.npy` and onboarding progress still exist.

- [ ] **Step 5: Record exact evidence and commit**

Collect:

```bash
wc -c dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip
shasum -a 256 dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip
git rev-parse HEAD
```

Update `docs/session-handoff.md` with the exact commit, ZIP byte size, SHA-256, current Python pass/skip counts, icon acceptance, single-click acceptance, and final safety-test result.

Commit only the handoff record:

```bash
git add docs/session-handoff.md
git commit -m "docs: record control center release acceptance"
```

### Task 4: Review and update the GitHub branch

**Files:**
- Review: all changes from the merge base through Task 3
- Push: branch `codex/self-contained-onboarding`
- Update: existing draft pull request `https://github.com/wuyicn/mac-face-lock/pull/2`

**Interfaces:**
- Consumes: all verified commits and local acceptance evidence.
- Produces: a pushed source branch and updated draft PR; it does not create a public GitHub Release.

- [ ] **Step 1: Run final verification from the committed tree**

Run:

```bash
git status --short
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework ApplicationServices \
  -framework CoreGraphics
scripts/build-release.sh
git diff --check
```

Expected: the working tree is clean before generated ignored output, all gates pass, and the rebuilt release verifies.

- [ ] **Step 2: Review scope and secrets**

Run:

```bash
git diff --stat origin/codex/self-contained-onboarding...HEAD
git diff --check origin/codex/self-contained-onboarding...HEAD
git grep -n -I -E \
  '(OPENAI_API_KEY|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|ghp_[A-Za-z0-9]+)' \
  -- . \
  ':!docs/superpowers/plans/2026-07-20-control-center-click-and-icon.md'
```

Expected: only intended source, tests, icon, and documentation changed; no credential material is found.

- [ ] **Step 3: Push the verified branch**

```bash
git push origin codex/self-contained-onboarding
```

Expected: the remote branch updates successfully.

- [ ] **Step 4: Check the draft PR**

Confirm PR 2 points to `codex/self-contained-onboarding`, lists the click fix and application icon, and reports the actual verification commands and outcomes. Keep the PR in draft until the remaining fresh-account release gate is complete.

Do not create a GitHub Release automatically. The current beta remains ad-hoc signed and not notarized.
