#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$PROJECT_DIR/Tests/InboxState"
TEST_WORK="$(mktemp -d /private/tmp/fullscreen-inbox-state.XXXXXX)"
trap 'rm -rf "$TEST_WORK"' EXIT

# Only temporary source copies are instrumented. All production control flow is
# preserved; defaults, session/fullscreen boundaries and sound are isolated.
/usr/bin/python3 - "$PROJECT_DIR" "$TEST_DIR" "$TEST_WORK" <<'PY'
from pathlib import Path
import sys

project, tests, work = map(Path, sys.argv[1:])
sources = work / "Sources"
sources.mkdir()
for original in sorted((project / "Sources").glob("*.swift")):
    if original.name in {"main.swift", "PresentationAvailability.swift", "FullScreenAlert.swift"}:
        continue
    text = original.read_text()
    text = text.replace("UserDefaults.standard", "inboxTestDefaults")
    text = text.replace("UserDefaults = .standard", "UserDefaults = inboxTestDefaults")
    if original.name == "AppDelegate.swift":
        assert text.count('NSSound(named: "Glass")?.play()') == 1
        text = text.replace('NSSound(named: "Glass")?.play()', "inboxTestSoundCount += 1")
        text += "\n" + (tests / "AppDelegateFixture.swift").read_text()
    (sources / original.name).write_text(text)
for filename in ["TestBoundaries.swift", "main.swift"]:
    (sources / filename).write_text((tests / filename).read_text())
PY

# Bound both compilation and execution; no launch services, Bonjour listener,
# real lock notification, full-screen window or network send is started.
/usr/bin/python3 - "$TEST_WORK" <<'PY'
from pathlib import Path
import subprocess
import sys

work = Path(sys.argv[1])
binary = work / "inbox-state-tests"
command = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos13.0",
           "-module-cache-path", str(work / "module-cache")]
command += [str(p) for p in sorted((work / "Sources").glob("*.swift"))]
command += ["-o", str(binary), "-framework", "AppKit", "-framework", "Network", "-framework", "ServiceManagement"]
subprocess.run(command, check=True, timeout=120)
subprocess.run([str(binary)], check=True, timeout=20)
PY
