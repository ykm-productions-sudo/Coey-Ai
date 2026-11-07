#!/usr/bin/env bash
#
# Builds llama.xcframework for Coey Ai.
#
#   ./scripts/build_llama.sh                 # device slice (what an .ipa needs)
#   LLAMA_BUILDS="ios-device ios-sim" ./scripts/build_llama.sh
#
# Requires macOS + Xcode command line tools. In CI this runs before
# `xcodegen generate`, because project.yml links Frameworks/llama.xcframework.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${LLAMA_VERSION:-v0.9.0}"
BUILDS="${LLAMA_BUILDS:-ios-device}"

SRC="$ROOT/.build/llama.cpp"
DEST="$ROOT/Frameworks/llama.xcframework"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. This script must run on macOS with Xcode." >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake not found. Install it with: brew install cmake" >&2
  exit 1
fi

mkdir -p "$ROOT/.build" "$ROOT/Frameworks"

if [ ! -d "$SRC/.git" ]; then
  echo "==> cloning llama.cpp $VERSION"
  git clone --depth 1 --branch "$VERSION" \
    https://github.com/ggml-org/llama.cpp.git "$SRC"
fi

if [ ! -d "$SRC/build-apple/llama.xcframework" ]; then
  echo "==> building llama.xcframework ($BUILDS)"
  # shellcheck disable=SC2086
  ( cd "$SRC" && ./build-xcframework.sh $BUILDS )
fi

rm -rf "$DEST"
cp -R "$SRC/build-apple/llama.xcframework" "$DEST"
echo "==> ready: $DEST"
