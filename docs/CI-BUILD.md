# Building CB1 and its patched dependencies

`CB1` is a C11 static library (`dvbridge_core`) that runs inside a player's render path. It
does not build against stock FFmpeg or stock libplacebo:

- `CB1/CMakeLists.txt` **aborts** unless `libavutil/dovi_meta.h` carries the `dvbridge_*` fields,
  which only exist after the CB1 FFmpeg patches;
- libplacebo must be the revision recorded in `CB1/config/dependencies.json` **with the CB1
  patches applied** — 20 of them, and they are sequential, so applying them one at a time
  against a clean tree reports false failures.

Both sources are pinned by SHA256, taken from the project's own lock file:

| Source | Revision | SHA256 |
| --- | --- | --- |
| FFmpeg | 9.0 (`n9.0`) | `7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52` |
| libplacebo | `e2972fdd09adacd383656738d7d280f0cd84a761` | `2dc029b7686455054fb5e76dd8c084cbf4fa4159f33364c5b7f9afc8b3611811` |

## Locally

```sh
sudo apt-get install -y build-essential cmake meson ninja-build pkg-config nasm yasm \
  libvulkan-dev glslang-dev liblcms2-dev libxxhash-dev libunwind-dev python3-jinja2 \
  libdrm-dev libegl-dev libgles-dev
JOBS="$(nproc)" bash scripts/build-cb1.sh .build
```

Artefacts land in `out/` (patched `ffprobe`, the patched libav* libraries and headers, the CB1
engine library and its headers, plus `SHA256SUMS`). The script verifies each download against
the digest above and stops on a mismatch; it also compiles the exact `AVDOVIDmData` probe that
CB1's CMake uses, so a build that would be rejected at CB1 configure time fails here instead.

## In CI

`.github/workflows/build-cb1.yml` runs the same script on `ubuntu-24.04` (push to `main` on the
paths listed there, or manually) and uploads `out/` as the `cb1-engine-linux-x64` artefact.

## What this does not produce

An image or a player. CB1 needs a graphics context (GLES/EGL), GPU images and an HDMI output to
the display, and it is consumed by Kodi's render path: the engine built here is a build input for
that player, plus the metadata-capable FFmpeg libraries. Building the LibreELEC image itself is
the project's own release process (`sources.tar.zst` + `vendor-inputs.tar.zst`).
