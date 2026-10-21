#!/bin/sh
# Build gridify.app (double-click opens the window; drop images on the icon to
# open them). Usage: scripts/make-app.sh [DEST_DIR]   (default: /Applications)
set -eu

cd "$(dirname "$0")/.."
dest="${1:-/Applications}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
app="$build/gridify.app"

echo "compiling..."
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O gridify.swift -o "$app/Contents/MacOS/gridify"

echo "drawing icon..."
swiftc -O scripts/icon.swift -o "$build/icon"
"$build/icon" "$build/icon.png"
set_dir="$build/AppIcon.iconset"
mkdir "$set_dir"
for s in 16 32 128 256 512; do
  sips -z $s $s "$build/icon.png" --out "$set_dir/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$build/icon.png" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>gridify</string>
  <key>CFBundleDisplayName</key><string>gridify</string>
  <key>CFBundleIdentifier</key><string>com.github.tbaums.gridify</string>
  <key>CFBundleExecutable</key><string>gridify</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.image</string></array>
    </dict>
  </array>
</dict>
</plist>
EOF

# Ad-hoc signature so Gatekeeper treats it as a locally built app.
codesign --force --sign - "$app"

echo "installing to $dest/gridify.app..."
rm -rf "$dest/gridify.app"
cp -R "$app" "$dest/"
# Make Finder and Launch Services pick up the new icon and file types.
touch "$dest/gridify.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$dest/gridify.app"
echo "done: $dest/gridify.app"
