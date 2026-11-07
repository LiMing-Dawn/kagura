#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
NDK_LABEL="${NDK_LABEL:?set NDK_LABEL}"
ENV_FILE="$ROOT/out/termux/$NDK_LABEL/build.env"
[[ -f "$ENV_FILE" ]] || { echo "error: missing $ENV_FILE" >&2; exit 1; }
source "$ENV_FILE"

NAME="kagura-termux-${NDK_LABEL}-llvm${LLVM_MAJOR}-aarch64"
PKGROOT="$ROOT/out/termux/$NDK_LABEL/package/$NAME"
ARTIFACTS="$ROOT/out/artifacts"
rm -rf "$(dirname "$PKGROOT")"
mkdir -p "$PKGROOT" "$ARTIFACTS"
cp -a "$STAGE/." "$PKGROOT/"
[[ -f "$PKGROOT/bin/kagura" ]] || { echo "error: missing new Kagura compiler driver" >&2; exit 1; }
[[ -x "$PKGROOT/bin/kagura-opt" ]] || { echo "error: missing kagura-opt" >&2; exit 1; }

mkdir -p "$PKGROOT/share/kagura/integration"
cp -a "$ROOT/integration/android" "$PKGROOT/share/kagura/integration/"
cp -a "$ROOT/integration/cmake" "$PKGROOT/share/kagura/integration/"

cat > "$PKGROOT/TERMUX.md" <<EOF
# Kagura Termux bundle

- NDK: $NDK_LABEL
- LLVM: $LLVM_VERSION
- Android API used to build host tools: $ANDROID_API
- Architecture: aarch64

Kagura v0.4+ includes the Python 3.9+ \`bin/kagura\` compiler driver
as well as the static \`bin/kagura-opt\`. In Termux install Python:
\`pkg install python\`

Validate a configuration with \`bin/kagura --config-check policy.json\`.

For existing ndk-build wrappers, the original pipeline still works:
\`clang -emit-llvm -c source.c -o source.bc\`
\`bin/kagura-opt -O1 -kagura-config policy.json -kagura-config-strict source.bc -o protected.bc\`
\`clang -c protected.bc -o source.o\`

Link \`lib/libkagura_runtime.a\` for passes that require runtime
symbols, such as AES string protection. Match the NDK clang major/revision
to this Kagura build's LLVM version.
EOF

ARCHIVE="$ARTIFACTS/$NAME.tar.xz"
tar -C "$(dirname "$PKGROOT")" -cJf "$ARCHIVE" "$NAME"
(
  cd "$ARTIFACTS"
  sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)

echo "Created: $ARCHIVE"
