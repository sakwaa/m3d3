#!/bin/zsh
# One-time setup for the animation reference tools (everything stays in this folder, except
# the RTMPose weights, which rtmlib caches in ~/.cache/rtmlib).
#   .venv-pose : Python 3.13 + rtmlib / onnxruntime / OpenCV (2D pose, tracking, cycles)
#   .venv-mp   : Python 3.12 + MediaPipe (3D pose; MediaPipe has no 3.13 wheels)
#   models/    : MediaPipe pose landmarker (heavy)
# Needs Homebrew: ffmpeg, yt-dlp, uv, imagemagick.
set -e
cd "${0:A:h}"
export PATH=/opt/homebrew/bin:$PATH
for tool in ffmpeg yt-dlp uv magick; do
	command -v $tool >/dev/null || { echo "missing $tool: brew install ${tool/magick/imagemagick}"; exit 1; }
done
export UV_CACHE_DIR="$PWD/.uv-cache"
[ -d .venv-pose ] || uv venv -q --python 3.13 .venv-pose
VIRTUAL_ENV="$PWD/.venv-pose" uv pip install -q rtmlib onnxruntime opencv-python-headless numpy pillow
[ -d .venv-mp ] || uv venv -q --python 3.12 .venv-mp
VIRTUAL_ENV="$PWD/.venv-mp" uv pip install -q mediapipe opencv-python-headless numpy
mkdir -p models
[ -f models/pose_heavy.task ] || curl -sL -o models/pose_heavy.task \
	https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task
echo "ok: .venv-pose, .venv-mp, models/pose_heavy.task"
