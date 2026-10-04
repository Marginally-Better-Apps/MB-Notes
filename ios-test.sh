#!/usr/bin/env bash
# Gala Engine gate: run the unit tests on an available iPad simulator.
set -euo pipefail

command -v xcodegen >/dev/null && xcodegen generate --quiet

DERIVED_DATA="${GALA_BUILD_DIR:-${TMPDIR:-/tmp}/mbnotes-test}/TestDerivedData"
SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
ids = [d["udid"] for runtime, items in devices.items() if "iOS" in runtime for d in items if d["name"].startswith(("iPad", "iPhone"))]
ipads = [d["udid"] for runtime, items in devices.items() if "iOS" in runtime for d in items if d["name"].startswith("iPad")]
print((ipads or ids or [""])[0])
')"
test -n "$SIMULATOR_ID" || { echo "No available iPad or iPhone simulator" >&2; exit 1; }

xcodebuild -quiet \
  -project MBNotes.xcodeproj -scheme MBNotes \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -skipMacroValidation -skipPackagePluginValidation \
  test
