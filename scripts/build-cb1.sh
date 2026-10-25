#!/usr/bin/env bash
# Build the CB1 Dolby Vision engine together with the exact dependencies it requires.
#
# CB1 does not build against stock FFmpeg or stock libplacebo:
#   * CB1/CMakeLists.txt refuses to configure unless libavutil/dovi_meta.h carries the
#     "dvbridge_*" fields, i.e. the CB1 FFmpeg patches;
#   * libplacebo has to be the revision recorded in CB1/config/dependencies.json with the
#     CB1 patches applied (20 of them).
# Both sources are pinned by digest, so this script is reproducible and refuses to continue
# if a download does not match the recorded checksum.
#
# Usage: scripts/build-cb1.sh [workdir]     (default workdir: .build)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-"${REPO_ROOT}/.build"}"
OUT="${REPO_ROOT}/out"
CB1="${REPO_ROOT}/CB1"

FFMPEG_VER="9.0"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"
FFMPEG_SHA256="7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52"  # CB1 config/dependencies.json

LIBPLACEBO_REV="e2972fdd09adacd383656738d7d280f0cd84a761"
LIBPLACEBO_URL="https://github.com/haasn/libplacebo/archive/${LIBPLACEBO_REV}.tar.gz"
LIBPLACEBO_SHA256="2dc029b7686455054fb5e76dd8c084cbf4fa4159f33364c5b7f9afc8b3611811"

PREFIX="${WORK}/prefix"
JOBS="${JOBS:-$(nproc)}"

log() { printf '\n=== %s\n' "$*"; }

verify_digest() {   # verify_digest <file> <expected|empty>
  local file="$1" expected="$2" actual
  [ -n "$expected" ] || { echo "no digest recorded for ${file}, skipping check"; return 0; }
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: ${file} digest mismatch" >&2
    echo "  expected ${expected}" >&2
    echo "  got      ${actual}" >&2
    exit 1
  fi
  echo "digest ok: $(basename "$file")"
}

mkdir -p "$WORK" "$OUT" "$PREFIX"

# ---------------------------------------------------------------- sources
cd "$WORK"
if [ ! -f "ffmpeg-${FFMPEG_VER}.tar.xz" ]; then
  log "downloading FFmpeg ${FFMPEG_VER}"
  curl -fsSL -o "ffmpeg-${FFMPEG_VER}.tar.xz" "$FFMPEG_URL"
fi
verify_digest "ffmpeg-${FFMPEG_VER}.tar.xz" "$FFMPEG_SHA256"
[ -d "ffmpeg-${FFMPEG_VER}" ] || tar xf "ffmpeg-${FFMPEG_VER}.tar.xz"

if [ ! -f "libplacebo-${LIBPLACEBO_REV}.tar.gz" ]; then
  log "downloading libplacebo ${LIBPLACEBO_REV}"
  curl -fsSL -o "libplacebo-${LIBPLACEBO_REV}.tar.gz" "$LIBPLACEBO_URL"
fi
verify_digest "libplacebo-${LIBPLACEBO_REV}.tar.gz" "$LIBPLACEBO_SHA256"
[ -d "libplacebo-${LIBPLACEBO_REV}" ] || tar xf "libplacebo-${LIBPLACEBO_REV}.tar.gz"

# ---------------------------------------------------------------- patches
# Applied in numeric order: the later patches build on the earlier ones, so a per-patch
# dry run against a clean tree is meaningless (it reports false failures).
apply_all() {   # apply_all <srcdir> <patchdir>
  local src="$1" dir="$2" p n=0
  log "applying CB1 patches to ${src##*/} ($(ls "$dir"/*.patch | wc -l) patches)"
  for p in "$dir"/*.patch; do
    n=$((n + 1))
    printf '%2d  %-52s ' "$n" "$(basename "$p")"
    if patch -p1 -s -d "$src" <"$p" >/dev/null 2>&1; then
      echo ok
    else
      echo FAILED
      patch -p1 --dry-run -d "$src" <"$p" | grep -E 'FAILED|Reversed|Hunk' | head -3 || true
      exit 1
    fi
  done
}

# Idempotent: re-extract if patches are already applied, so the script can be re-run.
if grep -q "dvbridge_raw_magic" "ffmpeg-${FFMPEG_VER}/libavutil/dovi_meta.h" 2>/dev/null; then
  echo "FFmpeg already patched"
else
  apply_all "ffmpeg-${FFMPEG_VER}" "${CB1}/patches/ffmpeg"
fi

if grep -rqs "cb1_stable_pq" "libplacebo-${LIBPLACEBO_REV}/src" 2>/dev/null; then
  echo "libplacebo already patched"
else
  apply_all "libplacebo-${LIBPLACEBO_REV}" "${CB1}/patches/libplacebo"
fi

# ---------------------------------------------------------------- libplacebo
log "building patched libplacebo"
cd "libplacebo-${LIBPLACEBO_REV}"
if [ ! -d build ]; then
  meson setup build --buildtype=release --prefix="$PREFIX" \
    -Dvulkan=enabled -Dopengl=enabled -Dglslang=enabled \
    -Ddemos=false -Dtests=false
fi
ninja -C build -j"$JOBS"
ninja -C build install

# ---------------------------------------------------------------- ffmpeg
log "building patched FFmpeg (minimal: the DV metadata path, not a media player)"
cd "${WORK}/ffmpeg-${FFMPEG_VER}"
if [ ! -f config.h ]; then
  PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" ./configure \
    --prefix="$PREFIX" \
    --disable-doc --disable-network --disable-autodetect --disable-debug \
    --disable-programs --enable-ffprobe \
    --enable-gpl --enable-version3 \
    --enable-decoder=hevc --enable-parser=hevc \
    --enable-demuxer=mov,matroska,mpegts --enable-protocol=file \
    --enable-filter=null --enable-swscale
fi
make -j"$JOBS"
make install

# ---------------------------------------------------------------- CB1 engine
log "building CB1 (dvbridge_core)"
cmake -S "$CB1" -B "${WORK}/cb1-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$PREFIX"
cmake --build "${WORK}/cb1-build" -j"$JOBS"

# ---------------------------------------------------------------- verify
log "verifying what was built"
ffprobe_bin="${PREFIX}/bin/ffprobe"
[ -x "$ffprobe_bin" ] || { echo "ERROR: ffprobe not built" >&2; exit 1; }
"$ffprobe_bin" -hide_banner -version | head -2

# The header check CB1's CMake performs must pass against the installed tree too.
cat >"${WORK}/dovi_check.c" <<'EOF'
#include <libavutil/dovi_meta.h>
int main(void) {
    AVDOVIDmData d = {0};
    d.dvbridge_raw_magic = 0x41424456;
    d.dvbridge_original_length = sizeof(d.dvbridge_original_bytes);
    return d.dvbridge_original_length == 0;
}
EOF
cc -I"${PREFIX}/include" "${WORK}/dovi_check.c" -o "${WORK}/dovi_check"
"${WORK}/dovi_check" && echo "dvbridge metadata fields present in the built FFmpeg"

engine_lib="$(find "${WORK}/cb1-build" -name 'libdvbridge_core*' -o -name '*.a' | head -5)"
[ -n "$engine_lib" ] || { echo "ERROR: CB1 engine library not produced" >&2; exit 1; }
echo "CB1 engine artefacts:"; echo "$engine_lib"

# ---------------------------------------------------------------- package
log "packaging artefacts into out/"
mkdir -p "$OUT/include" "$OUT/lib" "$OUT/bin"
cp -a "${PREFIX}/bin/ffprobe" "$OUT/bin/" 2>/dev/null || true
cp -a "${PREFIX}/lib/"libavutil* "$PREFIX/lib/"libavcodec* "$PREFIX/lib/"libavformat* \
      "$PREFIX/lib/"libswscale* "$OUT/lib/" 2>/dev/null || true
cp -a "${PREFIX}/include/"libavutil "$PREFIX/include/"libavcodec "$PREFIX/include/"libavformat \
      "$OUT/include/" 2>/dev/null || true
cp -a "${WORK}/cb1-build"/*.a "$OUT/lib/" 2>/dev/null || true
cp -a "$CB1"/src/*.h "$OUT/include/" 2>/dev/null || true
sha256sum "$OUT"/bin/* "$OUT"/lib/* >"$OUT/SHA256SUMS" 2>/dev/null || true
ls -la "$OUT" "$OUT/bin" "$OUT/lib" | head -30

log "done"
