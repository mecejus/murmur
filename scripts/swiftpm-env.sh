# Sourced by scripts/swift.sh. Works around a Command Line Tools install that
# kept a stale PackageDescription .private.swiftinterface from an older
# release: the compiler prefers it over the current interface, so every
# Package.swift fails to link ("Undefined symbols ... Package.__allocating_init").
# When that is detected, point SwiftPM at a clean copy of the manifest API.
# Nothing outside ~/Library/Caches is touched.

_pm="$(dirname "$(xcrun --find swift)")/../lib/swift/pm"
_private="$_pm/ManifestAPI/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface"
_dylib="$_pm/ManifestAPI/libPackageDescription.dylib"

if [ -z "$SWIFTPM_CUSTOM_LIBS_DIR" ] && [ -f "$_private" ] && [ "$_dylib" -nt "$_private" ]; then
  _clean="$HOME/Library/Caches/murmur/swiftpm-libs"
  if [ ! -f "$_clean/ManifestAPI/libPackageDescription.dylib" ] || [ "$_dylib" -nt "$_clean/ManifestAPI/libPackageDescription.dylib" ]; then
    rm -rf "$_clean"
    mkdir -p "$_clean/ManifestAPI/PackageDescription.swiftmodule"
    cp "$_dylib" "$_clean/ManifestAPI/"
    for f in "$_pm"/ManifestAPI/PackageDescription.swiftmodule/*; do
      case "$f" in *.private.swiftinterface) ;; *) cp "$f" "$_clean/ManifestAPI/PackageDescription.swiftmodule/" ;; esac
    done
    [ -d "$_pm/ManifestAPI/CompilerPluginSupport.swiftmodule" ] && cp -R "$_pm/ManifestAPI/CompilerPluginSupport.swiftmodule" "$_clean/ManifestAPI/"
    [ -d "$_pm/PluginAPI" ] && cp -R "$_pm/PluginAPI" "$_clean/"
  fi
  export SWIFTPM_CUSTOM_LIBS_DIR="$_clean"
fi
unset _pm _private _dylib _clean
