#!/bin/bash
#
# MeshTracker → TestFlight, one command (docs/testflight-release.md).
# Ported from AutoShot's release framework (2026-07-11).
#
#   ios/scripts/release.sh [version] [--note "text"]        # MAINLINE train
#   ios/scripts/release.sh --exp <name> --note "text"       # EXPERIMENT train
#
# One bundle id (com.s3ni0r.meshtracker), one App Store Connect record —
# variants ship as separate RELEASE TRAINS inside the same TestFlight app
# and are switched on-device via the TestFlight build picker:
#
#   mainline    version = the v* tag on HEAD (or the explicit argument)
#               build   = `git rev-list HEAD --count` (monotonic, stateless)
#   experiment  version = <major.minor of nearest tag>.<train NNN ≥ 101>
#               build   = UTC yymmddHHMM (monotonic, collision-proof across
#                         branches sharing a train)
#
# Train numbers are registered once per experiment name in
# ios/scripts/trains.env (auto-assigned + auto-committed on first use).
#
# Every shipped build is IDENTIFIABLE: after the archive, the build's
# identity (train, branch, short sha, UTC date, the --note text) is
# injected into the app's Info.plist (plutil; the export step re-signs) —
# readable at runtime via Bundle.main (keys ASBuildTrain / ASBuildBranch /
# ASBuildSHA / ASBuildDate / ASShipNote) if the app ever surfaces them.
# After upload, the note is pushed to the build's TestFlight "What to Test"
# via the App Store Connect API (ios/scripts/asc_whats_new.swift).
#
# One-time setup (docs/testflight-release.md): the App Store Connect app
# record for com.s3ni0r.meshtracker, an ASC API key at
# ~/.appstoreconnect/private_keys/, and a git-ignored .release-env at the
# REPO ROOT with ASC_KEY_ID + ASC_ISSUER_ID.
#
set -euo pipefail
cd "$(dirname "$0")/.."          # → ios/

APP_NAME="MeshTracker"
SCHEME="MeshTracker"
BUNDLE_ID="com.s3ni0r.meshtracker"
TRAINS_FILE="scripts/trains.env"
ENV_FILE="../.release-env"       # repo root

# ── args ─────────────────────────────────────────────────────────────────
VER=""
EXP=""
NOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exp)  EXP="${2:?--exp needs an experiment name}"; shift 2 ;;
    --note) NOTE="${2:?--note needs text}"; shift 2 ;;
    -*)     echo "✗ unknown flag $1" >&2; exit 1 ;;
    *)      VER="$1"; shift ;;
  esac
done

if [[ -n "$EXP" && ! "$EXP" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "✗ experiment name must be [a-z0-9-] (got '$EXP')" >&2; exit 1
fi
if [[ -n "$EXP" && -z "$NOTE" ]]; then
  echo "✗ an experiment ship REQUIRES --note \"what this build is\" — it is the" >&2
  echo "  build's identity in TestFlight (docs/testflight-release.md)." >&2
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
SHA=$(git rev-parse --short HEAD)

# ── train / version / build resolution ───────────────────────────────────
if [[ -z "$EXP" ]]; then
  TRAIN="main"
  if [[ -z "$VER" ]]; then
    TAG=$(git tag --points-at HEAD | grep '^v' | sort -V | tail -1 || true)
    if [[ -z "$TAG" ]]; then
      echo "✗ HEAD carries no v* tag. Tag the release first (git tag -a vX.Y) or pass a version: ios/scripts/release.sh 2.1" >&2
      exit 1
    fi
    VER="${TAG#v}"
  fi
  BUILD=$(git rev-list HEAD --count)
  [[ -n "$NOTE" ]] || NOTE="Mainline $VER — $BRANCH@$SHA"
else
  TRAIN="$EXP"
  # Register the experiment's train number once (auto-commit keeps the
  # release reproducible from git — the tree must stay clean below).
  TRAIN_NO=$(grep -E "^${EXP}=" "$TRAINS_FILE" 2>/dev/null | cut -d= -f2 || true)
  if [[ -z "$TRAIN_NO" ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
      echo "✗ Working tree not clean — cannot register the new experiment train." >&2
      exit 1
    fi
    LAST=$(grep -E '^[a-z0-9-]+=[0-9]+$' "$TRAINS_FILE" 2>/dev/null | cut -d= -f2 | sort -n | tail -1 || true)
    TRAIN_NO=$(( ${LAST:-100} + 1 ))
    echo "${EXP}=${TRAIN_NO}" >> "$TRAINS_FILE"
    git add "$TRAINS_FILE"
    git commit -q -m "release: register experiment train ${EXP}=${TRAIN_NO}"
    SHA=$(git rev-parse --short HEAD)
    echo "→ registered experiment train ${EXP}=${TRAIN_NO} (committed)"
  fi
  # Version = MAJOR.MINOR of the nearest tag + the train number. The .1NN
  # patch component marks experiment trains; mainline stays x.y (hotfixes
  # x.y.z with z < 100 never collide).
  BASE_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
  if [[ -z "$BASE_TAG" ]]; then
    echo "✗ no v* tag reachable from HEAD — experiments derive their version from the nearest tag." >&2
    exit 1
  fi
  BASE="${BASE_TAG#v}"
  BASE="$(echo "$BASE" | cut -d. -f1-2)"
  VER="${BASE}.${TRAIN_NO}"
  BUILD=$(date -u +%y%m%d%H%M)
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ Working tree not clean — a release must be reproducible from git." >&2
  exit 1
fi

# App Store Connect API key (headless signing + upload + What to Test).
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
: "${ASC_KEY_ID:?✗ set ASC_KEY_ID in .release-env at the repo root (docs/testflight-release.md §setup)}"
: "${ASC_ISSUER_ID:?✗ set ASC_ISSUER_ID in .release-env at the repo root (docs/testflight-release.md §setup)}"
KEYFILE="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
if [[ ! -f "$KEYFILE" ]]; then
  echo "✗ Missing $KEYFILE — download the API key .p8 there (docs/testflight-release.md §setup)." >&2
  exit 1
fi

BUILT_AT="$(date -u +"%Y-%m-%d %H:%MZ")"
echo "══ release $VER (build $BUILD) · train $TRAIN · $BRANCH@$SHA ══"

# The xcodeproj is GENERATED (xcodegen, gitignored) — regenerate so the
# archive always matches the committed project.yml. There is no test gate
# in this project (yet); the Release archive is the compile check.
echo "── 1/3 xcodegen + Release archive ──"
command -v xcodegen >/dev/null || { echo "✗ xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
xcodegen generate >/dev/null
rm -rf dist && mkdir -p dist
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' \
  archive -archivePath "dist/$APP_NAME.xcarchive" \
  MARKETING_VERSION="$VER" CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEYFILE" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -quiet
echo "   ARCHIVE OK"

# Identity injection (identifiable builds): custom AS* keys added to the
# archived app's Info.plist — the export step below re-signs, so the seal
# stays valid. Dev builds never get these keys.
APP_PLIST="dist/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app/Info.plist"
plutil -insert ASBuildTrain  -string "$TRAIN"    "$APP_PLIST"
plutil -insert ASBuildBranch -string "$BRANCH"   "$APP_PLIST"
plutil -insert ASBuildSHA    -string "$SHA"      "$APP_PLIST"
plutil -insert ASBuildDate   -string "$BUILT_AT" "$APP_PLIST"
plutil -insert ASShipNote    -string "$NOTE"     "$APP_PLIST"
echo "   IDENTITY INJECTED ($TRAIN · $BRANCH@$SHA)"

# destination=upload ⇒ xcodebuild uploads straight to App Store Connect —
# no altool/Transporter step. manageAppVersionAndBuildNumber=false: WE own
# the numbers (train scheme above); silent server-side bumps would desync
# the build from its commit.
# MANUAL export signing: the team API key can create profiles via the raw ASC API but Xcode's
# cloud-managed signing rejects it ("Cloud signing permission error" — cloud-managed certs need
# an Admin key). So we pin the locally installed distribution cert + the App Store profile
# created by ios/scripts/asc_make_profile.swift (one-time; re-run it if the profile ever expires).
cat > dist/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>signingStyle</key><string>manual</string>
    <key>teamID</key><string>H6956Z7A2F</string>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>provisioningProfiles</key><dict>
        <key>$BUNDLE_ID</key><string>MeshTracker App Store</string>
    </dict>
</dict>
</plist>
PLIST

echo "── 2/3 export + upload to App Store Connect ──"
xcodebuild -exportArchive \
  -archivePath "dist/$APP_NAME.xcarchive" \
  -exportOptionsPlist dist/ExportOptions.plist \
  -exportPath dist/export \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEYFILE" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "── 3/3 TestFlight \"What to Test\" ──"
printf '%s\n\n— %s@%s · built %s' "$NOTE" "$BRANCH" "$SHA" "$BUILT_AT" > dist/whats_new.txt
if swift scripts/asc_whats_new.swift \
    --key-id "$ASC_KEY_ID" --issuer-id "$ASC_ISSUER_ID" --key-file "$KEYFILE" \
    --bundle-id "$BUNDLE_ID" --version "$VER" --build "$BUILD" \
    --notes-file dist/whats_new.txt; then
  echo "   WHAT TO TEST SET"
else
  echo "⚠ upload OK but setting What to Test failed (processing slow / API hiccup)."
  echo "  Re-run just this step later:"
  echo "  swift ios/scripts/asc_whats_new.swift --key-id $ASC_KEY_ID --issuer-id $ASC_ISSUER_ID \\"
  echo "    --key-file $KEYFILE --bundle-id $BUNDLE_ID --version $VER --build $BUILD \\"
  echo "    --notes-file ios/dist/whats_new.txt"
fi

echo "══ uploaded $APP_NAME $VER ($BUILD) · train $TRAIN ══"
echo "Internal testers see it after processing (~5–15 min, no Beta App Review;"
echo "ITSAppUsesNonExemptEncryption=NO skips compliance). Switch builds on-device"
echo "via TestFlight → $APP_NAME → the version list / Previous Builds."
