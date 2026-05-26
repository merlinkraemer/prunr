#!/usr/bin/env bash
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-prunr-notary-api}"
TEAM_ID="${NOTARY_TEAM_ID:-PM5QWB5426}"

cat <<'EOF'
Prunr notary setup
==================

Xcode being signed in does NOT configure `notarytool` / `make release`.
The CLI needs either:

  A) App Store Connect API key (.p8)  ← recommended, most reliable
  B) Apple ID + app-specific password  ← NOT your normal Apple ID password

If option B says "wrong credentials" you almost certainly used your login
password instead of an app-specific password from:
  https://appleid.apple.com/account/manage
  → Sign-In and Security → App-Specific Passwords → generate new

EOF

echo "  profile:  $PROFILE"
echo "  team id:  $TEAM_ID"
echo

if ! security find-identity -v -p codesigning | rg -q "Developer ID Application.*${TEAM_ID}"; then
  echo "error: no Developer ID Application certificate for team $TEAM_ID" >&2
  exit 1
fi
echo "Developer ID certificate: OK"
echo

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "Profile '$PROFILE' already configured."
  xcrun notarytool history --keychain-profile "$PROFILE" | head -5
  exit 0
fi

store_with_api_key() {
  local key_path="$1"
  local key_id="$2"
  local issuer="$3"
  # Do not pass --team-id with API keys; it makes notarytool reject the profile.
  xcrun notarytool store-credentials "$PROFILE" \
    --key "$key_path" \
    --key-id "$key_id" \
    --issuer "$issuer"
}

store_with_apple_id() {
  local apple_id="$1"
  if [[ -n "${NOTARY_PASSWORD:-}" ]]; then
    xcrun notarytool store-credentials "$PROFILE" \
      --apple-id "$apple_id" \
      --password "$NOTARY_PASSWORD" \
      --team-id "$TEAM_ID"
  else
    echo "Enter app-specific password (xxxx-xxxx-xxxx-xxxx), NOT your login password."
    xcrun notarytool store-credentials "$PROFILE" \
      --apple-id "$apple_id" \
      --team-id "$TEAM_ID"
  fi
}

if [[ -n "${NOTARY_API_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
  store_with_api_key "$NOTARY_API_KEY" "$NOTARY_KEY_ID" "$NOTARY_ISSUER"
elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
  store_with_apple_id "$NOTARY_APPLE_ID"
else
  echo "Choose setup method:"
  echo "  1) App Store Connect API key (recommended)"
  echo "  2) Apple ID + app-specific password"
  echo "  3) Cancel"
  echo
  echo "For option 1, create a Team key at:"
  echo "  https://appstoreconnect.apple.com/access/integrations/api"
  echo "  Users and Access → Integrations → Team Keys → + (Developer access)"
  echo "  Download the .p8 once — Apple won't show it again."
  echo
  read -r -p "Choice [1/2/3]: " choice
  case "$choice" in
    1)
      read -r -p "Path to .p8 file: " NOTARY_API_KEY
      read -r -p "Key ID (10 chars): " NOTARY_KEY_ID
      read -r -p "Issuer ID (UUID): " NOTARY_ISSUER
      store_with_api_key "$NOTARY_API_KEY" "$NOTARY_KEY_ID" "$NOTARY_ISSUER"
      ;;
    2)
      read -r -p "Apple ID email: " NOTARY_APPLE_ID
      store_with_apple_id "$NOTARY_APPLE_ID"
      ;;
    *)
      echo "Cancelled."
      exit 0
      ;;
  esac
fi

echo
echo "Verifying..."
xcrun notarytool history --keychain-profile "$PROFILE" | head -5
echo
echo "Done. Notarized release:"
echo "  export SPARKLE_BIN_DIR=\"\$PWD/.build/sparkle-tools/bin\""
echo "  CREATE_RELEASE_COMMIT=1 CREATE_RELEASE_TAG=1 PUBLISH_GITHUB_RELEASE=1 \\"
echo "    make release VERSION=0.1.5-alpha.2 BUILD=1"

cat <<'EOF'

Xcode-only alternative (no CLI credentials):
  1. Open Prunr.xcodeproj → Product → Archive
  2. Organizer → Distribute App → Developer ID → Upload
  3. Xcode notarizes using your signed-in account
  4. Export the notarized .app, zip it, run generate_appcast, upload to GitHub

That works for one-off releases but `make release` still needs option A or B above.
EOF
