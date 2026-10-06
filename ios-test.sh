#!/usr/bin/env bash
# Gala gate: shared engine, browser interactions, and two optimized native clients.
set -euo pipefail
: "${GALA_BUILD_DIR:?Gala build directory is required}"
: "${GALA_ARTIFACT_DIR:?Gala artifact directory is required}"
(cd CollaborationWeb && npm ci --no-audit --no-fund && npm test && npm run build && npm run test:e2e)
xcodegen generate --quiet
DERIVED_DATA="$GALA_BUILD_DIR/TestDerivedData"
SIMULATOR_CONFIG="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
for runtime,devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime: continue
    ipad=next((d for d in devices if d["name"].startswith("iPad mini")),None) or next((d for d in devices if d["name"].startswith("iPad")),None)
    iphone=next((d for d in devices if d["name"].startswith("iPhone")),None)
    if ipad and iphone:
        print(ipad["deviceTypeIdentifier"],iphone["deviceTypeIdentifier"],runtime);sys.exit(0)
sys.exit("No iOS simulator runtime")
')"
read -r SIMULATOR_TYPE HOST_TYPE SIMULATOR_RUNTIME <<< "$SIMULATOR_CONFIG"
SIMULATOR_ID="$(xcrun simctl create "Gala MB Collaboration guest $$" "$SIMULATOR_TYPE" "$SIMULATOR_RUNTIME")"
HOST_ID="$(xcrun simctl create "Gala MB Collaboration owner $$" "$HOST_TYPE" "$SIMULATOR_RUNTIME")"
python3 Scripts/collaboration_capture.py > "$GALA_BUILD_DIR/capture-server.log" 2>&1 &
CAPTURE_PID=$!
cleanup() {
  status=$?; trap - EXIT
  kill "$CAPTURE_PID" >/dev/null 2>&1 || true
  for device in "$SIMULATOR_ID" "$HOST_ID"; do
    xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    xcrun simctl delete "$device" >/dev/null 2>&1 || true
  done
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
BUILD_ARGS=(
  -quiet -project MBNotes.xcodeproj -scheme MBNotes -configuration Release
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID"
  -derivedDataPath "$DERIVED_DATA" -packageCachePath "$GALA_BUILD_DIR/SwiftPM"
  -skipMacroValidation -skipPackagePluginValidation -jobs 2 -parallel-testing-enabled NO
  ONLY_ACTIVE_ARCH=YES COMPILATION_CACHE_ENABLE_CACHING=NO ENABLE_TESTABILITY=YES
  MBNOTES_UI_AUTOMATION=YES MBNOTES_REPORT_URL=http://127.0.0.1:8765/report
)
# Other projects can invoke builds, Maestro, and captures outside Gala's queue.
wait_for_test_mac() {
python3 - <<'PYSEQUENTIAL'
import subprocess,time
for attempt in range(120):
    processes=subprocess.check_output(['ps','-axo','command'],text=True)
    active = any((line.startswith('java ') and 'maestro.cli.AppKt' in line) or line.startswith('/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ') or (line.startswith('bash ') and 'capture-store-screenshots.sh' in line) or (line.startswith('/Library/Developer/PrivateFrameworks/CoreSimulator.framework') and 'bootstatus' in line) for line in processes.splitlines())
    if not active: break
    if attempt==0: print('Waiting for the other build/test/capture run before starting Xcode tests.',flush=True)
    time.sleep(5)
else: raise SystemExit('Another build/test/capture run still owns the test Mac; retry the gate later.')
PYSEQUENTIAL
}
wait_for_test_mac
xcodebuild "${BUILD_ARGS[@]}" build-for-testing
APP="$DERIVED_DATA/Build/Products/Release-iphonesimulator/MBNotes.app"
python3 - "$APP/Info.plist" <<'PYINFO'
import plistlib,sys
info=plistlib.load(open(sys.argv[1],'rb'))
assert info['MBNotesUIAutomation']=='YES'
assert info['GalaReportURL']=='http://127.0.0.1:8765/report'
PYINFO
xcrun simctl boot "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
# Run local interactions before adding a second simulator to the 8 GB Mac.
GUEST_TEST="MBNotesUITests/CollaborationInteractionTests/testNativeGuestJoinsByAppLinkAndEditsTheOtherIOSOwnersNote"
wait_for_test_mac
xcodebuild "${BUILD_ARGS[@]}" -skip-testing:"$GUEST_TEST" -resultBundlePath "$GALA_ARTIFACT_DIR/Collaboration.xcresult" test-without-building
xcrun xcresulttool export attachments --path "$GALA_ARTIFACT_DIR/Collaboration.xcresult" --output-path "$GALA_ARTIFACT_DIR/screenshots/local"
xcrun simctl boot "$HOST_ID"
xcrun simctl bootstatus "$HOST_ID" -b
xcrun simctl install "$HOST_ID" "$APP"
xcrun simctl launch "$HOST_ID" com.marginallybetter.notes -collaborationTesting -openFirstNote -collaborationFixtureHost -appearance light -ApplePersistenceIgnoreState YES
python3 - <<'PYWAIT'
import time,urllib.request
for _ in range(60):
    try:
        with urllib.request.urlopen('http://127.0.0.1:8765/fixture',timeout=1) as response:
            if response.status==200: break
    except Exception: time.sleep(1)
else: raise SystemExit('Native collaboration owner did not become ready')
PYWAIT
wait_for_test_mac
xcodebuild "${BUILD_ARGS[@]}" -only-testing:"$GUEST_TEST" -resultBundlePath "$GALA_ARTIFACT_DIR/NativeGuest.xcresult" test-without-building
xcrun xcresulttool export attachments --path "$GALA_ARTIFACT_DIR/NativeGuest.xcresult" --output-path "$GALA_ARTIFACT_DIR/screenshots/guest"
# Test the published web client against the native owner after XCTest has finished.
xcrun simctl shutdown "$SIMULATOR_ID"
xcrun simctl terminate "$HOST_ID" com.marginallybetter.notes
python3 - "$GALA_ARTIFACT_DIR/capture/fixture.json" <<'PYRESET'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PYRESET
xcrun simctl launch "$HOST_ID" com.marginallybetter.notes -collaborationTesting -openFirstNote -collaborationFixtureHost -appearance light -ApplePersistenceIgnoreState YES
python3 - <<'PYWEBWAIT'
import time,urllib.request
for _ in range(60):
    try:
        with urllib.request.urlopen('http://127.0.0.1:8765/fixture',timeout=1) as response:
            if response.status==200: break
    except Exception: time.sleep(1)
else: raise SystemExit('Native web collaboration owner did not become ready')
PYWEBWAIT
PUBLIC_DEMO_URL="$(python3 -c 'import json; print(json.load(open("MBNotes/Resources/Collaboration.json"))["publicURL"])')"
(cd CollaborationWeb && MB_DEMO_URL="$PUBLIC_DEMO_URL" MB_NATIVE_FIXTURE_URL=http://127.0.0.1:8765/fixture npm run test:native-owner)
mkdir -p "$GALA_ARTIFACT_DIR/screenshots/browser"
cp CollaborationWeb/test-results/native-owner-browser-guest.png "$GALA_ARTIFACT_DIR/screenshots/browser/"
python3 - "$GALA_ARTIFACT_DIR/capture" <<'PYCAPTURE'
from pathlib import Path
import sys
root=Path(sys.argv[1])
assert list(root.glob('*.png')), 'No Gala screenshots arrived from the optimized app'
assert (root/'app.log').exists() and (root/'app.log').stat().st_size, 'No console output arrived from the optimized app'
PYCAPTURE
