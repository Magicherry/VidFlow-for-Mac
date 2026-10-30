#!/bin/bash
# Builds a self-contained aria2c for macOS (TLS through Apple's Security framework, so it links only to system
# libraries) and writes it to Helpers/aria2c. aria2 publishes no macOS binaries of its own.
#
#   scripts/build-aria2.sh            # universal (arm64 + x86_64)
#   scripts/build-aria2.sh arm64      # one architecture
set -euo pipefail

VERSION=1.37.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHS=("${@:-arm64 x86_64}")
# shellcheck disable=SC2206
ARCHS=(${ARCHS[*]})
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=14.0

curl -fsSL -o "$WORK/aria2.tar.xz" \
    "https://github.com/aria2/aria2/releases/download/release-$VERSION/aria2-$VERSION.tar.xz"

OUTPUTS=()
for ARCH in "${ARCHS[@]}"; do
    SRC="$WORK/src-$ARCH"
    mkdir -p "$SRC"
    tar -xf "$WORK/aria2.tar.xz" -C "$SRC" --strip-components=1
    (
        cd "$SRC"
        FLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2"
        # Keg-only Homebrew libraries must not leak in: only the system's are wanted.
        env -u PKG_CONFIG_PATH PKG_CONFIG_LIBDIR=/nonexistent PATH=/usr/bin:/bin:/usr/sbin:/sbin \
            ./configure --host="$( [ "$ARCH" = arm64 ] && echo aarch64 || echo x86_64 )-apple-darwin" \
            --build="$(uname -m | sed s/arm64/aarch64/)-apple-darwin" \
            --with-appletls --without-openssl --without-gnutls --without-libgcrypt --without-libnettle \
            --without-libgmp --without-libssh2 --without-libcares --without-libuv --without-libxml2 \
            --without-sqlite3 --without-libexpat --disable-nls --disable-dependency-tracking \
            ZLIB_CFLAGS="" ZLIB_LIBS="-lz" \
            CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)" \
            CFLAGS="$FLAGS" CXXFLAGS="$FLAGS -std=c++14" LDFLAGS="$FLAGS" >/dev/null
        env PATH=/usr/bin:/bin:/usr/sbin:/sbin make -j"$(sysctl -n hw.ncpu)" -C deps >/dev/null 2>&1 || true
        env PATH=/usr/bin:/bin:/usr/sbin:/sbin make -j"$(sysctl -n hw.ncpu)" -C src aria2c >/dev/null
    )
    xcrun strip -x "$SRC/src/aria2c"
    OUTPUTS+=("$SRC/src/aria2c")
done

DEST="$ROOT/Helpers"
mkdir -p "$DEST"
xcrun lipo -create "${OUTPUTS[@]}" -output "$DEST/aria2c"
chmod 755 "$DEST/aria2c"
xcrun otool -L "$DEST/aria2c"
"$DEST/aria2c" --version | head -3
