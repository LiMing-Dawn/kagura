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

mkdir -p "$PKGROOT/share/kagura/integration"
cp -a "$ROOT/integration/android" "$PKGROOT/share/kagura/integration/"
cp -a "$ROOT/integration/cmake" "$PKGROOT/share/kagura/integration/"

cat > "$PKGROOT/TERMUX.md" <<EOF
# Kagura Termux bundle

- NDK: $NDK_LABEL
- LLVM: $LLVM_VERSION
- Android API used to build host tools: $ANDROID_API
- Architecture: aarch64

The primary entry point is \`bin/kagura-opt\`. Kagura passes are statically
linked into the tool, so LLVM 17-22 share the same invocation model:

\`clang -emit-llvm -c source.c -o source.bc\`
\`bin/kagura-opt -kagura-config share/kagura/profiles/balanced.json source.bc -o protected.bc\`
\`clang protected.bc lib/libkagura_runtime.a -o app\`

Use a compiler from the matching Homu android-ndk-custom release. Do not mix
this bundle with another LLVM major/revision.
EOF

ARCHIVE="$ARTIFACTS/$NAME.tar.xz"
tar -C "$(dirname "$PKGROOT")" -cJf "$ARCHIVE" "$NAME"
(
  cd "$ARTIFACTS"
  sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)

echo "Created: $ARCHIVE"
