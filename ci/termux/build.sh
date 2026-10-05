#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
NDK_LABEL="${NDK_LABEL:?set NDK_LABEL, e.g. r29}"
ANDROID_API="${ANDROID_API:-24}"
LLVM_PKG="${LLVM_PKG:-bolt+clang+clang-tools-extra+lld+polly}"
HOMU_OWNER="${HOMU_OWNER:-HomuHomu833}"

[[ "$NDK_LABEL" =~ ^r([0-9]+)(.*)$ ]] || {
  echo "error: unsupported NDK label syntax: $NDK_LABEL" >&2
  exit 2
}
NDK_MAJOR="${BASH_REMATCH[1]}"

WORK_BASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kagura-termux-${NDK_LABEL}"
DOWNLOADS="$WORK_BASE/downloads"
UNPACK="$WORK_BASE/unpack"
BUILD_DIR="$WORK_BASE/build"
STAGE="$ROOT/out/termux/$NDK_LABEL/stage"
ENV_FILE="$ROOT/out/termux/$NDK_LABEL/build.env"

rm -rf "$WORK_BASE" "$ROOT/out/termux/$NDK_LABEL"
mkdir -p "$DOWNLOADS" "$UNPACK/ndk" "$UNPACK/llvm" "$STAGE" "$(dirname "$ENV_FILE")"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    ((n < 4)) || return 1
    sleep $((n * 3))
  done
}

NDK_ASSET="android-ndk-${NDK_LABEL}-aarch64-linux-android.tar.xz"
LLVM_ASSET="${LLVM_PKG}-${NDK_LABEL}-aarch64-linux-android.tar.xz"

log "Downloading Homu NDK ${NDK_LABEL}"
retry gh release download "r${NDK_MAJOR}" \
  --repo "$HOMU_OWNER/android-ndk-custom" \
  --pattern "$NDK_ASSET" \
  --dir "$DOWNLOADS" --clobber \
  || die "NDK asset not found: $NDK_ASSET"

log "Downloading matching Homu llvm-custom for NDK ${NDK_LABEL}"
retry gh release download "llvm-r${NDK_MAJOR}" \
  --repo "$HOMU_OWNER/llvm-custom" \
  --pattern "$LLVM_ASSET" \
  --dir "$DOWNLOADS" --clobber \
  || die "LLVM asset not found: $LLVM_ASSET"

log "Extracting toolchains"
tar -xJf "$DOWNLOADS/$NDK_ASSET" -C "$UNPACK/ndk"
tar -xJf "$DOWNLOADS/$LLVM_ASSET" -C "$UNPACK/llvm"

NDK_PROPS="$(find "$UNPACK/ndk" -type f -name source.properties -print -quit)"
[[ -n "$NDK_PROPS" ]] || die "could not locate source.properties in NDK archive"
NDK_ROOT="$(dirname "$NDK_PROPS")"

LLVM_CMAKE_FILE="$(find "$UNPACK/llvm" -type f -path '*/lib/cmake/llvm/LLVMConfig.cmake' -print -quit)"
[[ -n "$LLVM_CMAKE_FILE" ]] || die "llvm-custom archive has no LLVMConfig.cmake"
LLVM_DIR="$(dirname "$LLVM_CMAKE_FILE")"
LLVM_ROOT="${LLVM_DIR%/lib/cmake/llvm}"
LLVM_CONFIG="$LLVM_ROOT/bin/llvm-config"
[[ -x "$LLVM_CONFIG" ]] || die "llvm-config is missing or not executable: $LLVM_CONFIG"

NDK_PREBUILT=""
for candidate in \
  "$NDK_ROOT/toolchains/llvm/prebuilt/linux-arm64" \
  "$NDK_ROOT/toolchains/llvm/prebuilt/linux-aarch64"; do
  if [[ -d "$candidate" ]]; then NDK_PREBUILT="$candidate"; break; fi
done
if [[ -z "$NDK_PREBUILT" ]]; then
  NDK_PREBUILT="$(find "$NDK_ROOT/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d -name 'linux-*' -print -quit)"
fi
[[ -n "$NDK_PREBUILT" ]] || die "could not locate NDK LLVM prebuilt directory"

LLVM_VERSION="$($LLVM_CONFIG --version)"
LLVM_MAJOR="${LLVM_VERSION%%.*}"
[[ "$LLVM_MAJOR" =~ ^[0-9]+$ ]] || die "could not parse LLVM version: $LLVM_VERSION"
if (( LLVM_MAJOR < 17 || LLVM_MAJOR > 22 )); then
  die "Kagura currently supports LLVM 17-22; detected LLVM $LLVM_VERSION for $NDK_LABEL"
fi

HOST_CLANG="$NDK_PREBUILT/bin/clang"
[[ -x "$HOST_CLANG" ]] || die "NDK clang is missing: $HOST_CLANG"
CLANG_VERSION="$($HOST_CLANG --version | head -n 1)"
LLVM_TRIPLE="$($LLVM_CONFIG --host-target 2>/dev/null || true)"

log "NDK root       : $NDK_ROOT"
log "NDK clang      : $CLANG_VERSION"
log "LLVM root      : $LLVM_ROOT"
log "LLVM version   : $LLVM_VERSION"
log "LLVM host      : ${LLVM_TRIPLE:-unknown}"
log "Android API    : $ANDROID_API"

log "Configuring static kagura-opt + Android runtime"
cmake -S "$ROOT" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM="android-${ANDROID_API}" \
  -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$LLVM_ROOT" \
  -DLLVM_DIR="$LLVM_DIR" \
  -DCMAKE_EXE_LINKER_FLAGS="-static -Wl,-z,max-page-size=16384" \
  -DKAGURA_BUILD_TESTS=OFF \
  -DKAGURA_BITCODE_TOOLS=ON \
  -DKAGURA_FORCE_STATIC_PLUGIN=ON \
  -DKAGURA_PCH=OFF \
  -DKAGURA_USE_CACHE=OFF

log "Building kagura-opt and runtime"
cmake --build "$BUILD_DIR" --target kagura-opt kagura_runtime -- -j"$(nproc)"

log "Installing"
cmake --install "$BUILD_DIR" --prefix "$STAGE"

KAGURA_OPT="$STAGE/bin/kagura-opt"
RUNTIME="$STAGE/lib/libkagura_runtime.a"
[[ -x "$KAGURA_OPT" ]] || die "installed kagura-opt is missing"
[[ -f "$RUNTIME" ]] || die "installed runtime is missing"

mkdir -p "$STAGE/share/kagura/metadata"
printf '%s\n' "$NDK_LABEL" > "$STAGE/share/kagura/metadata/ndk-version.txt"
printf '%s\n' "$ANDROID_API" > "$STAGE/share/kagura/metadata/android-api.txt"
printf '%s\n' "$LLVM_VERSION" > "$STAGE/share/kagura/metadata/llvm-version.txt"
printf '%s\n' "$CLANG_VERSION" > "$STAGE/share/kagura/metadata/clang-version.txt"
printf '%s\n' "$(git -C "$ROOT" rev-parse HEAD)" > "$STAGE/share/kagura/metadata/kagura-commit.txt"
printf '%s\n' "${LLVM_TRIPLE:-unknown}" > "$STAGE/share/kagura/metadata/llvm-host-target.txt"

cat > "$ENV_FILE" <<EOF
ROOT=$(printf '%q' "$ROOT")
NDK_LABEL=$(printf '%q' "$NDK_LABEL")
ANDROID_API=$(printf '%q' "$ANDROID_API")
NDK_ROOT=$(printf '%q' "$NDK_ROOT")
NDK_PREBUILT=$(printf '%q' "$NDK_PREBUILT")
LLVM_ROOT=$(printf '%q' "$LLVM_ROOT")
LLVM_DIR=$(printf '%q' "$LLVM_DIR")
LLVM_VERSION=$(printf '%q' "$LLVM_VERSION")
LLVM_MAJOR=$(printf '%q' "$LLVM_MAJOR")
STAGE=$(printf '%q' "$STAGE")
KAGURA_OPT=$(printf '%q' "$KAGURA_OPT")
RUNTIME=$(printf '%q' "$RUNTIME")
EOF

log "Build complete: $STAGE"
