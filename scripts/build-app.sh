#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
source "$root/scripts/identity.sh"
VERSION="${RELEASE_VERSION:-$VERSION}"
BUILD="${RELEASE_BUILD:-$BUILD}"
cd "$root"
out="$root/build"
app="$out/$APP_NAME.app"
sparkle="$root/vendor/Sparkle"

"$root/scripts/fetch-sparkle.sh"
mkdir -p "$out"

ictool="$HOME/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ictool" ]] || ictool="/Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ -x "$ictool" ]]; then
  if [[ ! -f "$out/AppIcon.icns" || scripts/icon/make-icon-doc.py -nt "$out/AppIcon.icns" || scripts/icon/compose-icon.swift -nt "$out/AppIcon.icns" ]]; then
    python3 -I scripts/icon/make-icon-doc.py "$out/AppIcon.icon" "${APP_ICON:-wave}" >/dev/null
    "$ictool" "$out/AppIcon.icon" --export-image --output-file "$out/icon-glass.png" \
      --platform macOS --rendition Default --width 824 --height 824 --scale 1 >/dev/null
    swiftc -O scripts/icon/compose-icon.swift -o "$out/compose-icon"
    "$out/compose-icon" "$out/icon-glass.png" "$out/icon-1024.png"
    rm -rf "$out/AppIcon.iconset"; mkdir -p "$out/AppIcon.iconset"
    for s in 16 32 128 256 512; do
      sips -z $s $s "$out/icon-1024.png" --out "$out/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
      sips -z $((s*2)) $((s*2)) "$out/icon-1024.png" --out "$out/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$out/AppIcon.iconset" -o "$out/AppIcon.icns"
  fi
elif [[ ! -f "$out/AppIcon.icns" || docs/icon.png -nt "$out/AppIcon.icns" ]]; then
  rm -rf "$out/AppIcon.iconset"; mkdir -p "$out/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s docs/icon.png --out "$out/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) docs/icon.png --out "$out/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$out/AppIcon.iconset" -o "$out/AppIcon.icns"
fi

rm -rf "$out"/*.app(N)
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$app/Contents/Info.plist"
plist="$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$plist"
plutil -replace CFBundleName -string "$APP_NAME" "$plist"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$plist"
plutil -replace CFBundleExecutable -string "$EXECUTABLE" "$plist"
plutil -replace NSHumanReadableCopyright -string "© $PUBLISHER · MIT License" "$plist"
plutil -replace SUFeedURL -string "$FEED_URL" "$plist"
plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$plist"
plutil -replace AppConfigDirName -string "$CONFIG_DIR_NAME" "$plist"
plutil -replace AppRepoURL -string "$REPO_URL" "$plist"
plutil -replace AppPreviousNames -string "${PREVIOUS_NAMES:-}" "$plist"
plutil -replace NSMicrophoneUsageDescription -string "$APP_NAME listens only while you hold the talk key, and turns what you say into text on this Mac." "$plist"
plutil -replace NSSpeechRecognitionUsageDescription -string "$APP_NAME uses Apple's on-device speech recognition to turn what you say into text." "$plist"
if [[ -d Resources/Sounds ]]; then
  ditto Resources/Sounds "$app/Contents/Resources/Sounds"
fi
cp "$out/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
swift build -c release --product "$EXECUTABLE" >/dev/null
bin="$(swift build -c release --show-bin-path)"
cp "$bin/$EXECUTABLE" "$app/Contents/MacOS/$EXECUTABLE"
for bundle in "$bin"/*.bundle(N); do
  ditto "$bundle" "$app/Contents/Resources/${bundle:t}"
done
ditto "$sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
  "$app/Contents/Frameworks/Sparkle.framework/XPCServices"

sign_id="$SIGN_IDENTITY"
if ! security find-certificate -c "$sign_id" >/dev/null 2>&1; then
  [[ "${IDENTITY_RELEASE:-0}" == 1 ]] && { print -u2 "Signing certificate '$sign_id' not found. Run scripts/make-cert.sh."; exit 1; }
  sign_id="-"
fi
sign() { codesign --force --timestamp=none --options runtime --sign "$sign_id" "$@"; }
fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$fw/Autoupdate"
sign "$fw/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$root/Resources/App.entitlements" "$app"
codesign --verify --deep --strict "$app"
print -r -- "$app"
