#!/usr/bin/env bash
# 交叉编译 netdisk-ffi 到 Android，产物直接放进 Flutter 的 jniLibs。
#
# 前置（本机当前尚未安装，见 docs/FLUTTER_CLIENT.md）：
#   - Android SDK + NDK（设置 ANDROID_NDK_HOME 或安装到 $ANDROID_HOME/ndk/<ver>）
#   - rustup target add aarch64-linux-android
#   - cargo install cargo-ndk
#
# 用法：在仓库根目录执行 `bash tools/build-android-ffi.sh`
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JNI_LIBS="$ROOT/app/android/app/src/main/jniLibs"

if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: cargo not found" >&2
  exit 1
fi
if ! cargo ndk --version >/dev/null 2>&1; then
  echo "ERROR: cargo-ndk missing. Install with: cargo install cargo-ndk" >&2
  exit 1
fi
if ! rustup target list --installed | grep -q '^aarch64-linux-android$'; then
  echo "ERROR: rust target missing. Run: rustup target add aarch64-linux-android" >&2
  exit 1
fi
if [[ -z "${ANDROID_NDK_HOME:-}" && -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
  echo "ERROR: set ANDROID_NDK_HOME (or ANDROID_HOME / ANDROID_SDK_ROOT)" >&2
  exit 1
fi

mkdir -p "$JNI_LIBS"
cd "$ROOT"
cargo ndk -t arm64-v8a -o "$JNI_LIBS" build -p netdisk-ffi --release

echo "=== produced ==="
ls -l "$JNI_LIBS/arm64-v8a/libnetdisk_ffi.so"
echo "Flutter 打包时会自动把 jniLibs/<abi>/*.so 塞进 APK。"
