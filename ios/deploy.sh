#!/bin/zsh
# Exports the mesh builder, builds it for iPhone and installs + launches it over the
# network (the phone must be paired with this Mac, unlocked, on the same Wi-Fi).
#   ./deploy.sh            first paired iPhone
#   DEVICE=<id> ./deploy.sh  a specific device (xcrun devicectl list devices)
set -e
cd "$(dirname "$0")"
GODOT="${GODOT:-$HOME/Library/Application Support/Godot/app_userdata/Godots/versions/Godot_v4_7_2-stable_mono_macos_universal/Godot_mono.app/Contents/MacOS/Godot}"
TEAM="${TEAM:-YG85D9UFMP}"
BUNDLE=com.sakwa.m3d3meshbuilder
mkdir -p build && touch build/.gdignore  # Godot must not scan the Xcode output
"$GODOT" --headless --path . --export-debug "iOS" build/M3D3MeshBuilder.ipa
xcodebuild -project build/M3D3MeshBuilder.xcodeproj -scheme M3D3MeshBuilder -configuration Debug \
	-destination 'generic/platform=iOS' -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
	CODE_SIGN_STYLE=Automatic -derivedDataPath build/dd build -quiet
DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')}"
[ -n "$DEVICE" ] || { echo "No paired iPhone available."; exit 1; }
xcrun devicectl device install app --device "$DEVICE" build/dd/Build/Products/Debug-iphoneos/M3D3MeshBuilder.app
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE"
