#!/bin/bash
# Build a relocatable openconnect tree from pinned source:
#   build/stage/{bin/openconnect,lib/*.dylib,scripts/vpnc-script,MANIFEST.txt}
# Root runs these files, so nothing may load plugins or config from user-writable
# paths: GnuTLS is built without p11-kit, and nothing links Homebrew. The target
# is macOS 15, whatever this Mac runs, so the release works on older systems.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v pkg-config >/dev/null || { echo "Install pkg-config first: brew install pkgconf" >&2; exit 1; }

gmp_version=6.3.0
gmp_sha256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
nettle_version=4.0
nettle_sha256=3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094
gnutls_version=3.8.13
gnutls_sha256=ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e
openconnect_version=9.21
openconnect_sha256=5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58

minimum_macos=15.0
# Root-owned location read by GnuTLS at startup. It need not exist.
priority_file=/Library/PrivilegedHelperTools/labvpn/etc/gnutls-config

root="$PWD/build"
downloads="$root/downloads"
work="$root/src"
prefix="$root/prefix"
stage="$root/stage"
jobs="$(sysctl -n hw.ncpu)"
sdk="$(xcrun --show-sdk-path)"

fetch() {
  local url="$1" expected="$2" path
  path="$downloads/$(basename "$url")"
  [[ -f "$path" ]] || curl -fsSL "$url" -o "$path"
  [[ "$(shasum -a 256 "$path" | awk '{print $1}')" == "$expected" ]] || {
    echo "Hash mismatch for $path" >&2
    exit 1
  }
  tar -xf "$path" -C "$work"
}

rm -rf "$work" "$prefix" "$stage"
mkdir -p "$downloads" "$work" "$prefix" "$stage/bin" "$stage/lib" "$stage/scripts"
fetch "https://ftpmirror.gnu.org/gmp/gmp-$gmp_version.tar.xz" "$gmp_sha256"
fetch "https://ftpmirror.gnu.org/nettle/nettle-$nettle_version.tar.gz" "$nettle_sha256"
fetch "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-$gnutls_version.tar.xz" "$gnutls_sha256"
fetch "https://www.infradead.org/openconnect/download/openconnect-$openconnect_version.tar.gz" "$openconnect_sha256"

export MACOSX_DEPLOYMENT_TARGET="$minimum_macos"
export CFLAGS="-O2 -mmacosx-version-min=$minimum_macos"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$prefix/include"
export LDFLAGS="-L$prefix/lib -mmacosx-version-min=$minimum_macos"
# Keep configure from finding anything in Homebrew.
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"

(
  cd "$work/gmp-$gmp_version"
  ./configure --prefix="$prefix" --enable-shared --disable-static --disable-cxx
  make -j"$jobs"
  make install
)

(
  cd "$work/nettle-$nettle_version"
  ./configure --prefix="$prefix" --libdir="$prefix/lib" --enable-shared --disable-static \
    --disable-documentation --disable-openssl \
    --with-include-path="$prefix/include" --with-lib-path="$prefix/lib"
  make -j"$jobs"
  make install
)

export NETTLE_CFLAGS="-I$prefix/include" NETTLE_LIBS="-L$prefix/lib -lnettle"
export HOGWEED_CFLAGS="-I$prefix/include" HOGWEED_LIBS="-L$prefix/lib -lhogweed"
export GMP_CFLAGS="-I$prefix/include" GMP_LIBS="-L$prefix/lib -lgmp"

(
  cd "$work/gnutls-$gnutls_version"
  ./configure --prefix="$prefix" --disable-static --disable-doc --disable-tests \
    --disable-tools --disable-cxx --disable-guile --disable-nls --disable-libdane \
    --without-p11-kit --without-tpm --without-tpm2 --without-idn --without-brotli \
    --without-zstd --with-included-libtasn1 --with-included-unistring \
    --with-system-priority-file="$priority_file" \
    --with-default-trust-store-file= --with-default-trust-store-dir= \
    --with-default-trust-store-pkcs11=
  make -j"$jobs"
  make install
)

(
  cd "$work/openconnect-$openconnect_version"
  GNUTLS_CFLAGS="-I$prefix/include" \
  GNUTLS_LIBS="-L$prefix/lib -lgnutls $HOGWEED_LIBS $NETTLE_LIBS $GMP_LIBS" \
  LIBXML2_CFLAGS="-I$sdk/usr/include/libxml2" LIBXML2_LIBS="-lxml2" \
  ZLIB_CFLAGS="" ZLIB_LIBS="-lz" \
  ./configure --prefix="$prefix" --disable-static --disable-nls --disable-docs \
    --with-gnutls --without-openssl --without-stoken --without-libpskc \
    --without-libpcsclite --without-gssapi --without-lz4 \
    --with-vpnc-script=/Library/PrivilegedHelperTools/labvpn/scripts/labvpn-vpnc-wrapper.sh
  make -j"$jobs"
  make install
)

cp "$prefix/bin/openconnect" "$stage/bin/" 2>/dev/null || cp "$prefix/sbin/openconnect" "$stage/bin/"
# Kept in the repo, with its networksetup calls removed: they clear hand-set DNS
# on disconnect and always fail on connect. scutil does the real work.
cp Resources/vpnc-script "$stage/scripts/vpnc-script"
chmod u+w "$stage/bin/openconnect"

non_system_deps() {
  otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/)' || true
}

queue=("$stage/bin/openconnect")
while [[ ${#queue[@]} -gt 0 ]]; do
  current="${queue[0]}"
  queue=("${queue[@]:1}")
  for dep in $(non_system_deps "$current"); do
    name="$(basename "$dep")"
    [[ "$name" == "$(basename "$current")" ]] && continue
    if [[ ! -e "$stage/lib/$name" ]]; then
      real="$(readlink -f "$prefix/lib/$name")"
      [[ -f "$real" ]] || { echo "Cannot find $dep" >&2; exit 1; }
      cp "$real" "$stage/lib/$name"
      chmod u+w "$stage/lib/$name"
      queue+=("$real")
    fi
  done
done

rewrite() {
  local file="$1" target="$2"
  for dep in $(non_system_deps "$file"); do
    [[ "$(basename "$dep")" == "$(basename "$file")" ]] && continue
    install_name_tool -change "$dep" "$target/$(basename "$dep")" "$file" 2>/dev/null
  done
}

for lib in "$stage"/lib/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$lib")" "$lib" 2>/dev/null
  rewrite "$lib" "@loader_path"
  codesign --force --sign - "$lib" 2>/dev/null
done
rewrite "$stage/bin/openconnect" "@executable_path/../lib"
codesign --force --sign - "$stage/bin/openconnect" 2>/dev/null

if for file in "$stage"/bin/openconnect "$stage"/lib/*.dylib; do otool -L "$file" | tail -n +2; done \
  | grep -E '/opt/homebrew|/usr/local|p11-kit|build/prefix'; then
  echo "Staged files still link outside the stage" >&2
  exit 1
fi

for file in "$stage"/bin/openconnect "$stage"/lib/*.dylib; do
  found="$(vtool -show-build "$file" | awk '/minos/ {print $2}')"
  [[ "$found" == "$minimum_macos" ]] || { echo "$file targets macOS $found, not $minimum_macos" >&2; exit 1; }
done

{
  "$stage/bin/openconnect" --version | head -2
  echo "gmp-$gmp_version sha256 $gmp_sha256"
  echo "nettle-$nettle_version sha256 $nettle_sha256"
  echo "gnutls-$gnutls_version sha256 $gnutls_sha256"
  echo "openconnect-$openconnect_version sha256 $openconnect_sha256"
  (cd "$stage" && shasum -a 256 bin/openconnect lib/*.dylib scripts/vpnc-script)
} > "$stage/MANIFEST.txt"
echo "Built openconnect with $(ls "$stage/lib" | wc -l | tr -d ' ') libraries in $stage"
