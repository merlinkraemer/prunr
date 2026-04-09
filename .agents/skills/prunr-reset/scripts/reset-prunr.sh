#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
APP_NAME="Prunr"
APP_PATH="/Applications/${APP_NAME}.app"
BUNDLE_ID="com.prunr.app"
APP_SUPPORT_DIR="${HOME}/Library/Application Support/Prunr"

STATE_PATHS=(
  "${HOME}/Library/Caches/${BUNDLE_ID}"
  "${HOME}/Library/Caches/Prunr"
  "${HOME}/Library/HTTPStorages/${BUNDLE_ID}"
  "${HOME}/Library/Saved Application State/${BUNDLE_ID}.savedState"
  "${HOME}/Library/Preferences/${BUNDLE_ID}.plist"
)

echo "Stopping running ${APP_NAME} instances..."
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 1

if [ -e "${APP_PATH}" ]; then
  echo "Removing installed app at ${APP_PATH}..."
  rm -rf "${APP_PATH}"
else
  echo "No installed app found at ${APP_PATH}."
fi

echo "Removing Application Support data..."
rm -rf "${APP_SUPPORT_DIR}"

echo "Removing cached state..."
for path in "${STATE_PATHS[@]}"; do
  rm -rf "${path}"
done

defaults delete "${BUNDLE_ID}" 2>/dev/null || true

echo "Rebuilding and reinstalling ${APP_NAME}..."
cd "${ROOT_DIR}"
make install-app

echo "Fresh install ready at ${APP_PATH}"
