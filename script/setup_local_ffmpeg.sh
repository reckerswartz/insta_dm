#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${HOME}/.local/bin"
mkdir -p "${TARGET_DIR}"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

ARCHIVE_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
ARCHIVE_PATH="${TMP_DIR}/ffmpeg-static.tar.xz"

echo "Downloading ffmpeg static build..."
curl -fsSL "${ARCHIVE_URL}" -o "${ARCHIVE_PATH}"

echo "Extracting archive..."
tar -xf "${ARCHIVE_PATH}" -C "${TMP_DIR}"

SRC_DIR="$(find "${TMP_DIR}" -maxdepth 1 -type d -name 'ffmpeg-*-amd64-static' | head -n1)"
if [[ -z "${SRC_DIR}" ]]; then
  echo "Unable to locate extracted ffmpeg directory." >&2
  exit 1
fi

cp "${SRC_DIR}/ffmpeg" "${TARGET_DIR}/ffmpeg"
cp "${SRC_DIR}/ffprobe" "${TARGET_DIR}/ffprobe"
chmod +x "${TARGET_DIR}/ffmpeg" "${TARGET_DIR}/ffprobe"

echo "Installed:"
"${TARGET_DIR}/ffmpeg" -version | head -n 1
echo "Use FFMPEG_BIN=${TARGET_DIR}/ffmpeg if PATH does not include ${TARGET_DIR}"
