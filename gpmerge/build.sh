#!/usr/bin/env bash
# Build gpmerge as a static aarch64 binary for Android.
set -euo pipefail

NDK="${NDK:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
CC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android30-clang"

[ -x "$CC" ] || { echo "NDK clang not found at $CC (set NDK=...)" >&2; exit 1; }

cd "$(dirname "$0")"
"$CC" -O2 -Wall -Wextra -static -o gpmerge gpmerge.c
# Publishes the NSO GameCube pad as an evdev node for gpmerge to pick up. Built
# and shipped alongside it because it is the same kind of thing — a small root
# binary the module installs — and it is useless without the merger anyway.
"$CC" -O2 -Wall -Wextra -static -o nsofeed nsofeed.c

# The Magisk module ships the binaries, but they are build artifacts rather than
# source, so keep the copies in step here instead of committing them.
cp gpmerge magisk/gpmerge
cp nsofeed magisk/nsofeed
chmod 755 magisk/gpmerge magisk/nsofeed

echo "built: $(pwd)/gpmerge, $(pwd)/nsofeed (copied into magisk/)"
file gpmerge nsofeed 2>/dev/null || true
