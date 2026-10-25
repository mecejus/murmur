#!/bin/sh
# Removes the murmur service, binary, logs and signing keychain.
# Keeps the model and config unless --purge is given.
set -e

LABEL="com.murmur"
BIN="$HOME/.local/bin/murmur"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/murmur"
SUPPORT="$HOME/Library/Application Support/murmur"
LOG_DIR="$HOME/Library/Logs/murmur"
KEYCHAIN="$HOME/Library/Keychains/murmur-signing.keychain-db"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$BIN"
rm -rf "$LOG_DIR"
if [ -f "$KEYCHAIN" ]; then
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || rm -f "$KEYCHAIN"
fi
rm -f "$CONFIG_DIR/signing-keychain-password" "$CONFIG_DIR/access-prompted" "$SUPPORT/murmur.lock"

if [ "$1" = "--purge" ]; then
  rm -rf "$CONFIG_DIR" "$SUPPORT"
  echo "murmur, its config and its models are removed."
else
  echo "murmur is removed. Kept: $CONFIG_DIR and the models in $SUPPORT/models"
  echo "(run with --purge to remove those too)."
fi
echo "macOS keeps murmur in System Settings > Privacy & Security > Accessibility"
echo "and Microphone until you remove it there (minus button). Leaving it is harmless."
