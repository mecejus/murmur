#!/bin/sh
# Builds murmur from this checkout, installs it as a per-user launchd
# service, and downloads the default model if it is not there yet.
# Run it again to update. No sudo needed.
set -e
cd "$(dirname "$0")"

LABEL="com.murmur"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/murmur"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/murmur"
LOG_DIR="$HOME/Library/Logs/murmur"
MODEL_DIR="$HOME/Library/Application Support/murmur/models"
MODEL="ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
MODEL_SHA1="e050f7970618a659205450ad97eb95a18d69c9ee"

# macOS ties an Accessibility grant to the binary's code signature. An ad hoc
# signature binds it to one build's hash, so every rebuild would need the
# grant removed and re-added by hand. Signing with a certificate binds it to
# the certificate instead. The certificate is created once, on this Mac, in
# its own keychain.
SIGN_IDENTITY="murmur-local"
SIGN_IDENTIFIER="com.murmur"
KEYCHAIN="$HOME/Library/Keychains/murmur-signing.keychain-db"
KEYCHAIN_PW_FILE="$CONFIG_DIR/signing-keychain-password"

[ "$(uname)" = "Darwin" ] || { echo "murmur needs macOS" >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "murmur needs Apple Silicon (M1 or later)" >&2; exit 1; }
xcrun --find swift >/dev/null 2>&1 || {
  echo "Swift is missing. Install the Command Line Tools first: xcode-select --install" >&2
  exit 1
}

have_identity() {
  [ -f "$KEYCHAIN" ] && [ -f "$KEYCHAIN_PW_FILE" ] &&
    security find-certificate -c "$SIGN_IDENTITY" "$KEYCHAIN" >/dev/null 2>&1
}

create_identity() {
  echo "Setting up local code signing (first time only)..."
  work=$(mktemp -d)
  cat > "$work/openssl.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $SIGN_IDENTITY
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
  # Apple's LibreSSL by full path: a Homebrew OpenSSL 3 writes PKCS12 files
  # that `security import` rejects.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -config "$work/openssl.cnf" -extensions ext \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$work/identity.p12" -passout pass:murmur -name "$SIGN_IDENTITY"
  pw=$(/usr/bin/openssl rand -hex 24)
  mkdir -p "$CONFIG_DIR"
  (umask 077 && printf '%s' "$pw" > "$KEYCHAIN_PW_FILE")
  [ -f "$KEYCHAIN" ] && security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  security create-keychain -p "$pw" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
  security import "$work/identity.p12" -k "$KEYCHAIN" -P murmur -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$KEYCHAIN" >/dev/null
  if ! security list-keychains -d user | grep -q "murmur-signing"; then
    # shellcheck disable=SC2046
    security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '" ')
  fi
  rm -rf "$work"
}

sign_binary() {
  have_identity || create_identity
  security unlock-keychain -p "$(cat "$KEYCHAIN_PW_FILE")" "$KEYCHAIN"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$SIGN_IDENTIFIER" --keychain "$KEYCHAIN" "$1"
}

echo "Building murmur (release)..."
scripts/swift.sh build -c release 2>&1 | grep -E "error|warning: unhandled|Compiling|Build complete" | tail -3
BUILT=".build/release/murmur"
[ -x "$BUILT" ] || { echo "Build failed." >&2; exit 1; }

if [ ! -f "$MODEL_DIR/$MODEL" ]; then
  echo "Downloading the speech model ($MODEL, about 550 MB, once)..."
  mkdir -p "$MODEL_DIR"
  curl -fL# "$MODEL_URL" -o "$MODEL_DIR/$MODEL.part"
  got=$(shasum -a 1 "$MODEL_DIR/$MODEL.part" | cut -d' ' -f1)
  if [ "$got" != "$MODEL_SHA1" ]; then
    rm -f "$MODEL_DIR/$MODEL.part"
    echo "The model download is corrupt (sha1 $got). Run install.sh again." >&2
    exit 1
  fi
  mv "$MODEL_DIR/$MODEL.part" "$MODEL_DIR/$MODEL"
fi

# Stop the running copy before replacing the binary.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

REGRANT=0
if [ -f "$BIN" ] && ! codesign -dv "$BIN" 2>&1 | grep -q "Authority=$SIGN_IDENTITY"; then
  REGRANT=1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp "$BUILT" "$TMP/murmur"
printf 'Signing...'
sign_binary "$TMP/murmur" 2>/dev/null
printf ' done\n'
mkdir -p "$BIN_DIR" "$LOG_DIR" "$CONFIG_DIR" "$(dirname "$PLIST")"
install -m 755 "$TMP/murmur" "$BIN"
echo "Installed $BIN"

# KeepAlive restarts murmur whenever it exits: after a crash, after an
# unrecoverable audio hang (exit 1), and on purpose while it waits for the
# Accessibility grant (exit 0; see Permissions.swift). ThrottleInterval 1 so
# a new grant is noticed within seconds. ProcessType Interactive keeps the
# scheduler from treating dictation as background work.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>run</string>
        <string>--wait-for-lock</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>1</integer>
    <key>ExitTimeOut</key>
    <integer>15</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.log</string>
</dict>
</plist>
PLIST

rm -f "$CONFIG_DIR/access-prompted"

LOG_START=0
[ -f "$LOG_DIR/launchd.log" ] && LOG_START=$(wc -l < "$LOG_DIR/launchd.log" | tr -d ' ')
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
if [ "$REGRANT" = 1 ] || ! "$BIN" check 2>/dev/null | grep -q "accessibility granted"; then
  echo "macOS will ask for Accessibility access (for the fn key and pasting)."
  echo "Click \"Open System Settings\" and switch murmur on. If murmur is already"
  echo "listed from an older build, remove it with the minus (-) button first."
  echo "It will also ask for the microphone the first time; click Allow."
  echo ""
fi

ticks=0
while [ "$ticks" -lt 1200 ]; do
  if tail -n +"$((LOG_START + 1))" "$LOG_DIR/launchd.log" 2>/dev/null | grep -q "murmur ready"; then
    echo "All set. Hold fn, talk, let go."
    exit 0
  fi
  printf '\rWaiting for murmur to start... %ss ' "$((ticks / 4))"
  sleep 0.25
  ticks=$((ticks + 1))
done
printf '\r'
echo "Still waiting; murmur starts by itself once Accessibility is switched on."
echo "Logs: $LOG_DIR/murmur.log"
