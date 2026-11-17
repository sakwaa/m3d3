#!/bin/zsh
# Builds our patched Godot (.NET) from a release tag: clone / fetch the tag, apply
# engine/patches/*.patch (3-way, so small upstream changes merge), build the editor, the
# .NET glue and assemblies, a runnable Godot_m3d3.app, and (TEMPLATES=1) the macOS export
# templates. Part of every engine upgrade:
#   GODOT_TAG=4.7.2-stable tools/engine/build.sh           # editor only
#   GODOT_TAG=4.8-stable TEMPLATES=1 tools/engine/build.sh # after an upgrade: editor + templates
# A patch that no longer applies stops the build: fix the conflict in $SRC, then refresh
# the patch and run again. Patches apply in order, each staged by `git apply --3way`, so
# a patch is the diff from the previous one: `git -C $SRC diff > <last>.patch` (after
# staging the ones before it), or `git -C $SRC diff HEAD` for the first.
# Env: GODOT_TAG (default below), SRC (checkout, default ~/workspace/godot-m3d3/godot),
# JOBS (default: CPU count - 1).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT_TAG="${GODOT_TAG:-4.7.2-stable}"
SRC="${SRC:-$HOME/workspace/godot-m3d3/godot}"
OUT="$(dirname "$SRC")"
JOBS="${JOBS:-$(( $(sysctl -n hw.ncpu) - 1 ))}"
export PATH="/opt/homebrew/bin:/opt/homebrew/opt/dotnet@8/bin:$PATH"
export DOTNET_ROOT="/opt/homebrew/opt/dotnet@8/libexec"
# (Engine.get_version_info().build: the game checks it for the patches, N64VideoOut.)
export BUILD_NAME="m3d3"
COMMON=(platform=macos arch=arm64 module_mono_enabled=yes vulkan=no)

echo "== Godot $GODOT_TAG in $SRC"
if [[ ! -d "$SRC/.git" ]]; then
	git clone --depth 1 --branch "$GODOT_TAG" https://github.com/godotengine/godot.git "$SRC"
else
	current="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || echo none)"
	if [[ "$current" != "$GODOT_TAG" ]]; then
		git -C "$SRC" stash push -m "m3d3 patches before $GODOT_TAG" >/dev/null || true
		git -C "$SRC" fetch --depth 1 origin tag "$GODOT_TAG"
		git -C "$SRC" checkout -q "$GODOT_TAG"
	fi
fi

echo "== Patches"
git -C "$SRC" reset -q --hard HEAD  # (start from the clean tag: index and files)
for p in "$REPO"/engine/patches/*.patch(N); do
	echo "   $(basename "$p")"
	git -C "$SRC" apply --3way --whitespace=nowarn "$p"
done

cd "$SRC"
echo "== Editor"
scons "${COMMON[@]}" target=editor -j"$JOBS"
BIN="bin/godot.macos.editor.arm64.mono"

echo "== .NET glue + assemblies"
"$BIN" --headless --generate-mono-glue modules/mono/glue
./modules/mono/build_scripts/build_assemblies.py --godot-output-dir=./bin --godot-platform=macos

echo "== App bundle"
APP="$OUT/Godot_m3d3.app"
rm -rf "$APP"
cp -R misc/dist/macos_tools.app "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Godot"
chmod +x "$APP/Contents/MacOS/Godot"
cp -R bin/GodotSharp "$APP/Contents/Resources/GodotSharp"
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "   $APP"

if [[ "${TEMPLATES:-0}" == "1" ]]; then
	echo "== Export templates (macOS)"
	scons "${COMMON[@]}" target=template_debug -j"$JOBS"
	scons "${COMMON[@]}" target=template_release -j"$JOBS"
	echo "   bin/godot.macos.template_{debug,release}.arm64.mono (custom templates for the macOS export preset)"
fi
echo "== Done ($GODOT_TAG + $(ls "$REPO"/engine/patches/*.patch(N) | wc -l | tr -d ' ') patch(es))"
