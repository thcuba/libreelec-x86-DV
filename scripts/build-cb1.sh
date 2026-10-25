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
# meson rejects a relative --prefix ("prefix value '.build/prefix' must be an absolute path"),
# and CI passes ".build", so the work dir is normalised here instead of trusting the caller.
case "$WORK" in
  /*) ;;
  *) WORK="${REPO_ROOT}/${WORK}" ;;
esac
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
OUT="${REPO_ROOT}/out"
# meson/autotools on Debian install into lib/<triplet>, so both pkg-config lookups and packaging
# must discover the actual directories instead of assuming ${PREFIX}/lib.
prefix_pc_path() { find "$PREFIX" -type d -name pkgconfig -print 2>/dev/null | tr '\n' ':'; }
prefix_has() { find "$PREFIX" -name "$1" -print -quit 2>/dev/null | grep -q .; }
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

# libplacebo generates its OpenGL loader at build time and looks for the "glad" Python
# module (>= 2.0) before anything else:
#   run_command([python, '-c', 'import glad; print(glad.__version__)'])
# The GitHub source archive does not carry it because upstream keeps glad as a git submodule,
# so without this libplacebo fails at meson setup with
#   "glad (required: >= 2.0, found: none) was not found in PYTHONPATH or 3rdparty".
if ! python3 -c 'import glad' >/dev/null 2>&1; then
  log "installing the glad generator (required by libplacebo's meson setup)"
  python3 -m pip install --quiet --break-system-packages glad2 2>/dev/null \
    || python3 -m pip install --quiet glad2
fi
python3 -c 'import glad; print("glad", glad.__version__)' || {
  echo "ERROR: the glad Python module is required by libplacebo" >&2
  exit 1
}

# libplacebo requires meson >= 1.3.0 at setup time; Debian 12 ships 1.0.1, which fails with
# "Meson version is 1.0.1 but project requires >=1.3.0". Ubuntu 24.04 (the CI image) has 1.3.2.
meson_ok() {
  python3 - <<'EOF' >/dev/null 2>&1
import subprocess, sys
out = subprocess.run(["meson", "--version"], capture_output=True, text=True).stdout.strip()
parts = out.split(".")
sys.exit(0 if len(parts) >= 2 and (int(parts[0]), int(parts[1])) >= (1, 3) else 1)
EOF
}
if ! meson_ok; then
  log "meson is older than 1.3 (libplacebo needs >=1.3.0): installing a newer one"
  python3 -m pip install --quiet --break-system-packages -U 'meson>=1.3' 2>/dev/null \
    || python3 -m pip install --quiet -U 'meson>=1.3'
fi
if ! meson_ok; then
  echo "ERROR: meson >= 1.3.0 is required to build libplacebo" >&2
  exit 1
fi
printf 'meson %s\n' "$(meson --version)"

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
# libplacebo looks for Vulkan headers inside 3rdparty/Vulkan-Headers and needs >= 1.4
# (VK_VERSION_1_4); Debian 12 ships 1.3.239, which makes meson abort with
# "Feature vulkan cannot be disabled: vulkan.h was not found on the system, nor inside
# 3rdparty/Vulkan-Headers". Upstream keeps them as a git submodule, absent from the archive.
VK_HEADERS="${WORK}/libplacebo-${LIBPLACEBO_REV}/3rdparty/Vulkan-Headers"
if [ ! -f "${VK_HEADERS}/include/vulkan/vulkan_core.h" ]; then
  log "fetching Vulkan-Headers into 3rdparty (libplacebo needs >= 1.4)"
  rm -rf "$VK_HEADERS"
  git clone --depth 1 --quiet https://github.com/KhronosGroup/Vulkan-Headers.git "$VK_HEADERS"
fi
grep -m1 "VK_VERSION_1_4" "${VK_HEADERS}/include/vulkan/vulkan_core.h" >/dev/null \
  && echo "Vulkan-Headers: 1.4+ present"

log "building patched libplacebo"
cd "libplacebo-${LIBPLACEBO_REV}"
# Check for build.ninja, not for the directory: a directory left behind by a failed meson
# setup exists but has no build.ninja, and ninja then dies with
# "ninja: error: loading 'build.ninja': No such file or directory".
if [ ! -f build/build.ninja ]; then
  rm -rf build
  meson setup build --buildtype=release --prefix="$PREFIX" \
    -Dvulkan=enabled -Dopengl=enabled -Dglslang=enabled \
    -Ddemos=false -Dtests=false
fi
if prefix_has 'libplacebo.so*'; then
  echo "libplacebo already installed in prefix, skipping the build"
else
  ninja -C build -j"$JOBS"
  ninja -C build install
fi

# ---------------------------------------------------------------- ffmpeg
log "building patched FFmpeg (minimal: the DV metadata path, not a media player)"
cd "${WORK}/ffmpeg-${FFMPEG_VER}"
if [ ! -f config.h ]; then
  PKG_CONFIG_PATH="$(prefix_pc_path)${PKG_CONFIG_PATH:-}" ./configure \
    --prefix="$PREFIX" \
    --disable-doc --disable-network --disable-autodetect --disable-debug \
    --disable-programs --enable-ffprobe \
    --enable-gpl --enable-version3 \
    --enable-decoder=hevc --enable-parser=hevc \
    --enable-demuxer=mov,matroska,mpegts --enable-protocol=file \
    --enable-filter=null --enable-swscale
fi
if [ -x "${PREFIX}/bin/ffprobe" ]; then
  echo "FFmpeg already installed in prefix, skipping the build"
else
  make -j"$JOBS"
  make install
fi

# ---------------------------------------------------------------- CB1 engine
log "building CB1 (dvbridge_core)"
# CB1/src/CMakeLists.txt resolves its dependencies with pkg_check_modules
# (libplacebo>=7.372.0, libavutil>=59.12.100, libavcodec>=62, glesv2, egl, libdrm, libva), so the
# prefix built here has to be visible to pkg-config or it would look at the system libraries.
PKG_CONFIG_PATH="$(prefix_pc_path)${PKG_CONFIG_PATH:-}" \
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
find "$PREFIX" \( -name 'libavutil*' -o -name 'libavcodec*' -o -name 'libavformat*' \
     -o -name 'libswscale*' -o -name 'libplacebo*' \) -type f \
     -exec cp -a {} "$OUT/lib/" \; 2>/dev/null || true
cp -a "${PREFIX}/include/"libavutil "$PREFIX/include/"libavcodec "$PREFIX/include/"libavformat \
      "$OUT/include/" 2>/dev/null || true
cp -a "${WORK}/cb1-build"/*.a "$OUT/lib/" 2>/dev/null || true
cp -a "$CB1"/src/*.h "$OUT/include/" 2>/dev/null || true
sha256sum "$OUT"/bin/* "$OUT"/lib/* >"$OUT/SHA256SUMS" 2>/dev/null || true
ls -la "$OUT" "$OUT/bin" "$OUT/lib" | head -30

log "done"
