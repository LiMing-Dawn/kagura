#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
NDK_LABEL="${NDK_LABEL:?set NDK_LABEL}"
ENV_FILE="$ROOT/out/termux/$NDK_LABEL/build.env"
[[ -f "$ENV_FILE" ]] || { echo "error: missing $ENV_FILE" >&2; exit 1; }
source "$ENV_FILE"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

TEST_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kagura-smoke-${NDK_LABEL}"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

NDK_PREBUILT="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"
if [[ ! -d "$NDK_PREBUILT" ]]; then
  NDK_PREBUILT="$(find "$NDK_ROOT/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d -name 'linux-*' -print -quit)"
fi
[[ -n "$NDK_PREBUILT" && -d "$NDK_PREBUILT" ]] || die "NDK LLVM prebuilt directory not found"

CC="$NDK_PREBUILT/bin/aarch64-linux-android${ANDROID_API}-clang"
[[ -x "$CC" ]] || CC="$NDK_PREBUILT/bin/clang"
TARGET_ARGS=()
if [[ "$(basename "$CC")" == "clang" ]]; then
  TARGET_ARGS+=("--target=aarch64-linux-android${ANDROID_API}")
fi

log "Checking kagura-opt is an executable static AArch64 binary"
file "$KAGURA_OPT"
readelf -h "$KAGURA_OPT" | grep -q 'Machine:.*AArch64' || die "kagura-opt is not AArch64"
if readelf -l "$KAGURA_OPT" | grep -q 'Requesting program interpreter'; then
  readelf -l "$KAGURA_OPT" >&2
  die "kagura-opt is dynamically linked; expected a static Bionic binary"
fi
qemu-aarch64 "$KAGURA_OPT" --help >/dev/null

cat > "$TEST_DIR/test.c" <<'EOF'
#include <stdio.h>
static const char kagura_secret[] = "KAGURA_TERMUX_SECRET_7E3B1A";
__attribute__((noinline)) static int protected_sum(int x) {
  int y = x * 13;
  if ((y & 1) != 0) y += 9; else y += 17;
  return y;
}
int main(void) {
  printf("%s:%d\n", kagura_secret, protected_sum(7));
  return 0;
}
EOF

compile_bc() {
  local out="$1"
  "$CC" "${TARGET_ARGS[@]}" -O1 -fno-lto -emit-llvm -c "$TEST_DIR/test.c" -o "$out"
}

link_and_run() {
  local bc="$1" exe="$2" expected="KAGURA_TERMUX_SECRET_7E3B1A:100"
  "$CC" "${TARGET_ARGS[@]}" -O1 -static -fuse-ld=lld \
    "$bc" "$RUNTIME" -Wl,-z,max-page-size=16384 -o "$exe"
  readelf -h "$exe" | grep -q 'Machine:.*AArch64' || die "$exe is not AArch64"
  local got
  got="$(qemu-aarch64 "$exe")"
  [[ "$got" == "$expected" ]] || die "runtime mismatch: expected '$expected', got '$got'"
}

log "Smoke: XOR string + flattening"
compile_bc "$TEST_DIR/base.bc"
qemu-aarch64 "$KAGURA_OPT" -O1 -kagura-str -kagura-fla "$TEST_DIR/base.bc" -o "$TEST_DIR/str-fla.bc"
if strings "$TEST_DIR/str-fla.bc" | grep -Fq 'KAGURA_TERMUX_SECRET_7E3B1A'; then
  die "XOR string pass left plaintext in transformed bitcode"
fi
link_and_run "$TEST_DIR/str-fla.bc" "$TEST_DIR/str-fla"

log "Smoke: AES-CTR string encryption"
compile_bc "$TEST_DIR/aes-base.bc"
qemu-aarch64 "$KAGURA_OPT" -O1 -kagura-str-aes "$TEST_DIR/aes-base.bc" -o "$TEST_DIR/aes.bc"
if strings "$TEST_DIR/aes.bc" | grep -Fq 'KAGURA_TERMUX_SECRET_7E3B1A'; then
  die "AES string pass left plaintext in transformed bitcode"
fi
link_and_run "$TEST_DIR/aes.bc" "$TEST_DIR/aes"

log "Smoke: VM virtualization"
compile_bc "$TEST_DIR/vm-base.bc"
qemu-aarch64 "$KAGURA_OPT" -O1 -kagura-vm -kagura-protect=protected_sum -S \
  "$TEST_DIR/vm-base.bc" -o "$TEST_DIR/vm.ll"
grep -Eq '@kagura_vm_execute|@kagura_vm_bc_' "$TEST_DIR/vm.ll" \
  || die "VM pass did not emit VM trampoline/bytecode globals"
grep -Eq 'call i64 @kagura_vm_execute|call.*@kagura_vm_execute' "$TEST_DIR/vm.ll" \
  || die "VM pass did not replace protected_sum with a VM trampoline"
link_and_run "$TEST_DIR/vm.ll" "$TEST_DIR/vm"

log "All smoke tests passed for $NDK_LABEL / LLVM $LLVM_VERSION"
