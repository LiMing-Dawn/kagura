#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
NDK_LABEL="${NDK_LABEL:?set NDK_LABEL, e.g. r29}"
ANDROID_API="${ANDROID_API:-24}"
HOMU_OWNER="${HOMU_OWNER:-HomuHomu833}"

[[ "$NDK_LABEL" =~ ^r([0-9]+)(.*)$ ]] || { echo "error: bad NDK label: $NDK_LABEL" >&2; exit 2; }
NDK_MAJOR="${BASH_REMATCH[1]}"

WORK_BASE="${RUNNER_TEMP:-/tmp}/kagura-termux-${NDK_LABEL}"
DOWNLOADS="$WORK_BASE/downloads"
UNPACK="$WORK_BASE/unpack"
LLVM_SRC="$WORK_BASE/llvm-project"
LLVM_BUILD="$WORK_BASE/llvm-build"
KAGURA_BUILD="$WORK_BASE/kagura-build"
STAGE="$ROOT/out/termux/$NDK_LABEL/stage"
ENV_FILE="$ROOT/out/termux/$NDK_LABEL/build.env"

rm -rf "$WORK_BASE" "$ROOT/out/termux/$NDK_LABEL"
mkdir -p "$DOWNLOADS" "$UNPACK/ndk" "$LLVM_BUILD" "$KAGURA_BUILD" "$STAGE" "$(dirname "$ENV_FILE")"

log(){ printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die(){ echo "error: $*" >&2; exit 1; }

NDK_ASSET="android-ndk-${NDK_LABEL}-x86_64-linux-gnu.tar.xz"
log "Downloading Homu build NDK: $NDK_ASSET"
gh release download "r${NDK_MAJOR}" --repo "$HOMU_OWNER/android-ndk-custom"   --pattern "$NDK_ASSET" --dir "$DOWNLOADS" --clobber   || die "missing NDK asset: $NDK_ASSET"

tar -xJf "$DOWNLOADS/$NDK_ASSET" -C "$UNPACK/ndk"
NDK_PROPS="$(find "$UNPACK/ndk" -type f -name source.properties -print -quit)"
[[ -n "$NDK_PROPS" ]] || die "source.properties not found"
NDK_ROOT="$(dirname "$NDK_PROPS")"

INFO="$(find "$NDK_ROOT" -type f -name clang_source_info.md -print -quit)"
[[ -n "$INFO" ]] || die "clang_source_info.md not found in $NDK_LABEL"

BASE_REV="$(sed -nE 's/^[[:space:]]*Base revision:[[:space:]]*([0-9a-f]{40}).*/\1/p' "$INFO" | head -n1)"
if [[ -z "$BASE_REV" ]]; then
  BASE_REV="$(grep -Eo '[0-9a-f]{40}' "$INFO" | head -n1 || true)"
fi
[[ "$BASE_REV" =~ ^[0-9a-f]{40}$ ]] || die "cannot parse LLVM base revision from $INFO"

log "LLVM base revision: $BASE_REV"
git clone --filter=blob:none --no-checkout https://github.com/llvm/llvm-project.git "$LLVM_SRC"
git -C "$LLVM_SRC" fetch --depth=1 origin "$BASE_REV"
git -C "$LLVM_SRC" checkout --detach FETCH_HEAD

# Apply Android cherry-picks recorded by clang_source_info.md when present.
# The file format has changed across NDK generations, so accept full 40-hex SHAs
# listed after the base revision and ignore duplicates/unknown commits.
mapfile -t EXTRA_REVS < <(grep -Eo '[0-9a-f]{40}' "$INFO" | awk -v base="$BASE_REV" '$0 != base' | awk '!seen[$0]++')
for rev in "${EXTRA_REVS[@]:-}"; do
  log "Trying Android cherry-pick $rev"
  if git -C "$LLVM_SRC" fetch --depth=1 origin "$rev" >/dev/null 2>&1; then
    git -C "$LLVM_SRC" cherry-pick --no-commit FETCH_HEAD || {
      git -C "$LLVM_SRC" cherry-pick --abort >/dev/null 2>&1 || true
      git -C "$LLVM_SRC" reset --hard HEAD
      log "Skipping non-clean cherry-pick $rev"
    }
  fi
done

NDK_TC="$NDK_ROOT/build/cmake/android.toolchain.cmake"
[[ -f "$NDK_TC" ]] || die "NDK CMake toolchain missing"

log "Building minimal LLVM development tree for Android/Bionic AArch64"
cmake -S "$LLVM_SRC/llvm" -B "$LLVM_BUILD" -G Ninja   -DCMAKE_TOOLCHAIN_FILE="$NDK_TC"   -DANDROID_ABI=arm64-v8a   -DANDROID_PLATFORM="android-${ANDROID_API}"   -DANDROID_STL=c++_static   -DCMAKE_BUILD_TYPE=Release   -DLLVM_TARGETS_TO_BUILD=AArch64   -DLLVM_ENABLE_PROJECTS=""   -DLLVM_ENABLE_RUNTIMES=""   -DLLVM_INCLUDE_TESTS=OFF   -DLLVM_INCLUDE_EXAMPLES=OFF   -DLLVM_INCLUDE_BENCHMARKS=OFF   -DLLVM_INCLUDE_DOCS=OFF   -DLLVM_ENABLE_TERMINFO=OFF   -DLLVM_ENABLE_ZLIB=OFF   -DLLVM_ENABLE_ZSTD=OFF   -DLLVM_ENABLE_LIBXML2=OFF   -DLLVM_ENABLE_LIBEDIT=OFF   -DLLVM_BUILD_TOOLS=ON   -DLLVM_BUILD_UTILS=ON   -DLLVM_INSTALL_UTILS=ON   -DLLVM_ENABLE_PIC=ON   -DLLVM_ENABLE_RTTI=OFF   -DLLVM_ENABLE_EH=OFF   -DLLVM_ENABLE_ASSERTIONS=OFF   -DLLVM_BUILD_LLVM_DYLIB=OFF   -DLLVM_LINK_LLVM_DYLIB=OFF

cmake --build "$LLVM_BUILD" --target   LLVMSupport LLVMCore LLVMAnalysis LLVMTransformUtils LLVMPasses   LLVMIRReader LLVMBitReader LLVMBitWriter llvm-tblgen -- -j"$(nproc)"

LLVM_DIR="$LLVM_BUILD/lib/cmake/llvm"
[[ -f "$LLVM_DIR/LLVMConfig.cmake" ]] || die "LLVMConfig.cmake not produced"
LLVM_CONFIG_VERSION="$(sed -nE 's/^set\(LLVM_PACKAGE_VERSION "([^"]+)".*/\1/p' "$LLVM_DIR/LLVMConfig.cmake" | head -n1)"
LLVM_MAJOR="${LLVM_CONFIG_VERSION%%.*}"
[[ "$LLVM_MAJOR" =~ ^[0-9]+$ ]] || die "cannot detect LLVM major"
if (( LLVM_MAJOR < 17 || LLVM_MAJOR > 22 )); then
  die "Kagura supports LLVM 17-22; detected $LLVM_CONFIG_VERSION"
fi

log "Building Kagura static kagura-opt + runtime"
cmake -S "$ROOT" -B "$KAGURA_BUILD" -G Ninja   -DCMAKE_TOOLCHAIN_FILE="$NDK_TC"   -DANDROID_ABI=arm64-v8a   -DANDROID_PLATFORM="android-${ANDROID_API}"   -DANDROID_STL=c++_static   -DCMAKE_BUILD_TYPE=Release   -DLLVM_DIR="$LLVM_DIR"   -DCMAKE_EXE_LINKER_FLAGS="-static -Wl,-z,max-page-size=16384"   -DKAGURA_BUILD_TESTS=OFF   -DKAGURA_BITCODE_TOOLS=ON   -DKAGURA_FORCE_STATIC_PLUGIN=ON   -DKAGURA_PCH=OFF   -DKAGURA_USE_CACHE=OFF

cmake --build "$KAGURA_BUILD" --target kagura-opt kagura_runtime -- -j"$(nproc)"
cmake --install "$KAGURA_BUILD" --prefix "$STAGE"

KAGURA_OPT="$STAGE/bin/kagura-opt"
RUNTIME="$STAGE/lib/libkagura_runtime.a"
[[ -f "$KAGURA_OPT" ]] || die "kagura-opt missing"
[[ -f "$RUNTIME" ]] || die "runtime missing"

mkdir -p "$STAGE/share/kagura/metadata"
cp "$INFO" "$STAGE/share/kagura/metadata/clang_source_info.md"
printf '%s\n' "$NDK_LABEL" > "$STAGE/share/kagura/metadata/ndk-version.txt"
printf '%s\n' "$ANDROID_API" > "$STAGE/share/kagura/metadata/android-api.txt"
printf '%s\n' "$BASE_REV" > "$STAGE/share/kagura/metadata/llvm-base-revision.txt"
printf '%s\n' "$LLVM_CONFIG_VERSION" > "$STAGE/share/kagura/metadata/llvm-version.txt"
printf '%s\n' "$(git -C "$ROOT" rev-parse HEAD)" > "$STAGE/share/kagura/metadata/kagura-commit.txt"

cat > "$ENV_FILE" <<EOF
ROOT=$(printf '%q' "$ROOT")
NDK_LABEL=$(printf '%q' "$NDK_LABEL")
ANDROID_API=$(printf '%q' "$ANDROID_API")
NDK_ROOT=$(printf '%q' "$NDK_ROOT")
LLVM_BUILD=$(printf '%q' "$LLVM_BUILD")
LLVM_DIR=$(printf '%q' "$LLVM_DIR")
LLVM_VERSION=$(printf '%q' "$LLVM_CONFIG_VERSION")
LLVM_MAJOR=$(printf '%q' "$LLVM_MAJOR")
STAGE=$(printf '%q' "$STAGE")
KAGURA_OPT=$(printf '%q' "$KAGURA_OPT")
RUNTIME=$(printf '%q' "$RUNTIME")
EOF

log "Build complete: $STAGE"
