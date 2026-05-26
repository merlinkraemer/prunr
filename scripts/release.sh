#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
BUILD="${2:-}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "usage: bash scripts/release.sh <version> <build>" >&2
  echo "note: BUILD (CFBundleVersion / sparkle:version) must always increase across releases." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="Prunr"
ARCHIVE_DIR="$ROOT_DIR/Releases"
ARCHIVE_PATH="$ARCHIVE_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$ARCHIVE_DIR/exported"
EXPORT_APP_PATH="$EXPORT_DIR/$SCHEME.app"
SUBMIT_ZIP_PATH="$ARCHIVE_DIR/$SCHEME-submit.zip"
DIST_DIR="$ROOT_DIR/dist/releases/v$VERSION"
USER_ZIP_PATH="$DIST_DIR/$SCHEME-$VERSION-build$BUILD-macos.zip"
DSYM_ZIP_PATH="$DIST_DIR/$SCHEME-$VERSION-build$BUILD-dSYM.zip"
CHECKSUM_PATH="$DIST_DIR/SHA256SUMS.txt"
DERIVED_DATA="$ROOT_DIR/.build/release-derived"
SOURCE_PACKAGES="$ROOT_DIR/.build/sourcePackages"
EXPORT_OPTIONS_PLIST="$ROOT_DIR/scripts/ExportOptions.plist"
APPCAST_PATH="$ROOT_DIR/docs/appcast.xml"
NOTARY_PROFILE="${NOTARY_PROFILE:-prunr-notary-api}"
TEAM_ID="PM5QWB5426"
PUBLISH_GITHUB_RELEASE="${PUBLISH_GITHUB_RELEASE:-0}"
CREATE_RELEASE_COMMIT="${CREATE_RELEASE_COMMIT:-0}"
CREATE_RELEASE_TAG="${CREATE_RELEASE_TAG:-0}"
RELEASE_REF="${RELEASE_REF:-$(git rev-parse HEAD)}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

warn() {
  echo "warning: $*" >&2
}

update_yaml_value() {
  local key="$1"
  local value="$2"
  perl -0pi -e "s/${key}: \".*?\"/${key}: \"$value\"/" "$ROOT_DIR/project.yml"
}

require_clean_tree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "working tree must be clean before running release.sh" >&2
    exit 1
  fi
}

maybe_create_release_commit() {
  if [[ "$CREATE_RELEASE_COMMIT" != "1" ]]; then
    return
  fi

  git add project.yml Prunr.xcodeproj/project.pbxproj docs/appcast.xml
  if [[ -n "$(git diff --cached --name-only)" ]]; then
    git commit -m "release: v$VERSION build $BUILD"
    RELEASE_REF="$(git rev-parse HEAD)"
  fi
}

maybe_create_release_tag() {
  if [[ "$CREATE_RELEASE_TAG" != "1" ]]; then
    return
  fi

  git tag "v$VERSION" "$RELEASE_REF"
}

release_notes_file() {
  local notes_file="$ROOT_DIR/.build/release-notes-v$VERSION.md"
  mkdir -p "$ROOT_DIR/.build"
  sed \
    -e "s/{{VERSION}}/$VERSION/g" \
    -e "s/{{BUILD}}/$BUILD/g" \
    "$ROOT_DIR/scripts/release-notes.md.tpl" > "$notes_file"
  printf '%s' "$notes_file"
}

maybe_publish_github_release() {
  if [[ "$PUBLISH_GITHUB_RELEASE" != "1" ]]; then
    return
  fi

  gh auth status >/dev/null

  local release_args=(
    release create "v$VERSION"
    "$USER_ZIP_PATH"
    "$DSYM_ZIP_PATH"
    "$CHECKSUM_PATH"
    --title "Prunr $VERSION"
    --notes-file "$(release_notes_file)"
  )

  if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    if git ls-remote --exit-code origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
      release_args+=(--verify-tag)
    fi
  fi

  gh "${release_args[@]}"
}

update_appcast_if_available() {
  if [[ ! -f "$APPCAST_PATH" ]]; then
    warn "docs/appcast.xml missing; skipping appcast update"
    return
  fi

  local sparkle_bin_dir="${SPARKLE_BIN_DIR:-}"
  local appcast_tool=""
  local sign_tool=""

  if [[ -n "$sparkle_bin_dir" ]]; then
    appcast_tool="$sparkle_bin_dir/generate_appcast"
    sign_tool="$sparkle_bin_dir/sign_update"
  fi

  if [[ -x "$appcast_tool" ]]; then
    "$appcast_tool" \
      --download-url-prefix "https://github.com/merlinkraemer/prunr/releases/download/v$VERSION/" \
      --link "https://github.com/merlinkraemer/prunr/releases/tag/v$VERSION" \
      "$DIST_DIR"

    local generated_appcast="$DIST_DIR/appcast.xml"
    if [[ -f "$generated_appcast" ]]; then
      cp "$generated_appcast" "$APPCAST_PATH"
    else
      warn "generate_appcast completed without producing $generated_appcast"
    fi
    return
  fi

  if [[ -x "$sign_tool" ]]; then
    warn "sign_update is available but generate_appcast is not; leaving docs/appcast.xml unchanged"
    "$sign_tool" "$USER_ZIP_PATH" >/dev/null || warn "sign_update failed for $USER_ZIP_PATH"
    return
  fi

  warn "Sparkle tools not found; skipping appcast/signature generation"
}

require_command git
require_command xcodebuild
require_command xcodegen
require_command xcrun
require_command codesign
require_command spctl
require_command ditto
require_command shasum

require_clean_tree

if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
  echo "missing export options plist: $EXPORT_OPTIONS_PLIST" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "notary profile '$NOTARY_PROFILE' is not configured or inaccessible" >&2
  exit 1
fi

if [[ "$PUBLISH_GITHUB_RELEASE" == "1" ]]; then
  require_command gh
fi

update_yaml_value "MARKETING_VERSION" "$VERSION"
update_yaml_value "CURRENT_PROJECT_VERSION" "$BUILD"

xcodegen generate

rm -rf "$ARCHIVE_DIR" "$DIST_DIR" "$DERIVED_DATA"
mkdir -p "$ARCHIVE_DIR" "$DIST_DIR"

xcodebuild archive \
  -project "$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

if [[ ! -d "$EXPORT_APP_PATH" ]]; then
  echo "exported app not found at $EXPORT_APP_PATH" >&2
  exit 1
fi

ditto -c -k --keepParent "$EXPORT_APP_PATH" "$SUBMIT_ZIP_PATH"

xcrun notarytool submit "$SUBMIT_ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$EXPORT_APP_PATH"
codesign --verify --deep --strict --verbose=2 "$EXPORT_APP_PATH"
spctl --assess --type execute --verbose=4 "$EXPORT_APP_PATH"
xcrun stapler validate "$EXPORT_APP_PATH"

ditto -c -k --keepParent "$EXPORT_APP_PATH" "$USER_ZIP_PATH"

DSYM_PATH="$ARCHIVE_PATH/dSYMs/$SCHEME.app.dSYM"
if [[ -d "$DSYM_PATH" ]]; then
  ditto -c -k --keepParent "$DSYM_PATH" "$DSYM_ZIP_PATH"
else
  warn "dSYM not found at $DSYM_PATH"
fi

(
  cd "$DIST_DIR"
  shasum -a 256 ./*.zip > "$CHECKSUM_PATH"
)

update_appcast_if_available
maybe_create_release_commit
maybe_create_release_tag
maybe_publish_github_release

cat <<EOF
release prepared:
  app: $EXPORT_APP_PATH
  zip: $USER_ZIP_PATH
  dSYM: $DSYM_ZIP_PATH
  checksums: $CHECKSUM_PATH

optional remote steps:
  CREATE_RELEASE_COMMIT=1 CREATE_RELEASE_TAG=1 PUBLISH_GITHUB_RELEASE=1 make release VERSION=$VERSION BUILD=$BUILD
EOF
