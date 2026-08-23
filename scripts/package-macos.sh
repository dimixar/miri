#!/usr/bin/env bash
set -euo pipefail

app_name="Miri"
executable_name="miri"
bundle_id="io.github.mariarcks.miri"
minimum_system_version="13.0"

version="0.0.0"
build_number="${MIRI_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
output_dir="dist"
skip_build=0
keep_stage=0

usage() {
  cat <<'EOF'
Usage: scripts/package-macos.sh [options]

Options:
  --version VERSION       Release version used in artifact names.
  --build-number NUMBER  Bundle build number. Defaults to UTC timestamp.
  --output-dir DIR       Output directory. Defaults to dist.
  --skip-build           Reuse the existing .build release binary.
  --keep-stage           Keep the temporary .app/.dmg staging directory.
  -h, --help             Show this help.

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:?missing value for --version}"
      shift 2
      ;;
    --build-number)
      build_number="${2:?missing value for --build-number}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --keep-stage)
      keep_stage=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS packaging requires a Darwin host." >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "macOS packaging currently targets arm64 hosts only." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$repo_root/$output_dir"
stage_root="$output_dir/stage/arm64-darwin"
volume_root="$stage_root/volume"
app_dir="$volume_root/$app_name.app"
dmg_path="$output_dir/$app_name-$version-arm64-darwin.dmg"
binary_path="$repo_root/.build/arm64-apple-macosx/release/$executable_name"
icon_source="$repo_root/assets/MiriIcon.png"
adaptive_icon_source="$repo_root/assets/Miri.icon"
adaptive_icon_name=""

if [[ "$skip_build" != "1" ]]; then
  swift build -c release --arch arm64
fi

if [[ ! -x "$binary_path" ]]; then
  fallback_binary="$repo_root/.build/release/$executable_name"
  if [[ -x "$fallback_binary" ]]; then
    binary_path="$fallback_binary"
  else
    echo "Release binary not found at $binary_path" >&2
    exit 1
  fi
fi

if [[ ! -f "$icon_source" ]]; then
  echo "App icon source not found at $icon_source" >&2
  exit 1
fi

marketing_version="${version%%[-+]*}"
if [[ ! "$marketing_version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
  marketing_version="0.0.0"
fi

rm -rf "$stage_root" "$dmg_path"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$output_dir"

cp "$binary_path" "$app_dir/Contents/MacOS/$executable_name"
chmod 755 "$app_dir/Contents/MacOS/$executable_name"
cp "$repo_root/LICENSE" "$app_dir/Contents/Resources/LICENSE"

# Xcode 26 and macOS 26 can render Icon Composer assets for the current
# appearance. Keep this optional so contributors with older Xcode versions can
# still create a package using the static icon below.
if [[ -d "$adaptive_icon_source" ]] && xcrun --find actool >/dev/null 2>&1; then
  adaptive_info_plist="$stage_root/MiriIcon-partial.plist"
  if xcrun actool "$adaptive_icon_source" \
    --compile "$app_dir/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target "$minimum_system_version" \
    --target-device mac \
    --app-icon "$app_name" \
    --output-partial-info-plist "$adaptive_info_plist" \
    --output-format human-readable-text \
    --warnings \
    --notices; then
    adaptive_icon_name="$app_name"
  else
    echo "warning: adaptive icon compilation failed; using the static icon" >&2
    rm -f "$app_dir/Contents/Resources/Assets.car"
  fi
fi

iconset_dir="$stage_root/Miri.iconset"
mkdir -p "$iconset_dir"

render_icon() {
  local size="$1"
  local filename="$2"
  sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/$filename" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/Miri.icns"
rm -rf "$iconset_dir"

cat > "$app_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$app_name</string>
  <key>CFBundleExecutable</key>
  <string>$executable_name</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleIconFile</key>
  <string>Miri.icns</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$app_name</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$marketing_version</string>
  <key>CFBundleVersion</key>
  <string>$build_number</string>
  <key>LSMinimumSystemVersion</key>
  <string>$minimum_system_version</string>
  <key>LSUIElement</key>
  <true/>
  <key>MiriReleaseVersion</key>
  <string>$version</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

if [[ -n "$adaptive_icon_name" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleIconName string $adaptive_icon_name" \
    "$app_dir/Contents/Info.plist"
fi

codesign --force --deep --sign - "$app_dir"

ln -s /Applications "$volume_root/Applications"
hdiutil create \
  -volname "$app_name $version" \
  -srcfolder "$volume_root" \
  -ov \
  -format UDZO \
  "$dmg_path"

if [[ "$keep_stage" != "1" ]]; then
  rm -rf "$stage_root"
fi

echo "Created $dmg_path"
