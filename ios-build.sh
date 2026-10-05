#!/usr/bin/env bash
# Gala Engine recipe: build an unsigned Release device IPA.
set -euo pipefail

: "${GALA_BUILD_DIR:?Gala build directory is required}"
: "${GALA_ARTIFACT_DIR:?Gala artifact directory is required}"

command -v xcodegen >/dev/null && xcodegen generate --quiet

DERIVED_DATA="$GALA_BUILD_DIR/DerivedData"
xcodebuild -quiet \
  -project MBNotes.xcodeproj -scheme MBNotes \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -skipMacroValidation -skipPackagePluginValidation \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  CODE_SIGNING_ALLOWED=NO build

APP="$DERIVED_DATA/Build/Products/Release-iphoneos/MBNotes.app"
test -d "$APP"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/mbnotes-gala.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload" "$GALA_ARTIFACT_DIR"
ditto "$APP" "$STAGE/Payload/MBNotes.app"
IPA="$GALA_ARTIFACT_DIR/MBNotes.ipa"
(cd "$STAGE" && zip -qry "$IPA" Payload)
shasum -a 256 "$IPA"
