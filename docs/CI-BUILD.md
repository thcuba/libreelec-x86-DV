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

## Inputs that are not in the source archives

Both trees come from GitHub archives, which **do not carry git submodules**. The script fetches
what libplacebo refuses to configure without:

| Input | Why it is needed | How the script provides it |
| --- | --- | --- |
| `glad` (Python module >= 2.0) | libplacebo generates its OpenGL loader at build time; `src/opengl/include/glad/meson.build` runs `import glad; print(glad.__version__)` and aborts with *"glad (required: >= 2.0, found: none) was not found in PYTHONPATH or 3rdparty"* | `pip install glad2` |
| Vulkan-Headers >= 1.4 | libplacebo needs `VK_VERSION_1_4` and looks for `3rdparty/Vulkan-Headers`; Debian 12 ships 1.3.239 and ubuntu-24.04 ships 1.3.275, both too old | cloned into `3rdparty/Vulkan-Headers`, then the header is checked for `VK_VERSION_1_4` |

## Dependencies the engine declares

`CB1/src/CMakeLists.txt` resolves everything through `pkg_check_modules`, so the build prefix has
to be visible to `pkg-config` (the script puts every `pkgconfig` directory found under the prefix
on `PKG_CONFIG_PATH`):

```
libplacebo >= 7.372.0   libavutil >= 59.12.100   libavcodec >= 62
glesv2   egl   libdrm   libva
```

LightGBM (`LightGBM/c_api.h` + `_lightgbm`) is required **only** when `CB1_ENABLE_HDR10_AI=ON`;
this build leaves it off.

Two environment traps worth knowing, both handled by the script:

- libplacebo requires **meson >= 1.3.0** and aborts otherwise (Debian 12 ships 1.0.1; the CI image
  has 1.3.2). The script installs a newer meson when the one on `PATH` is too old.
- On Debian, meson and autotools install into `lib/<triplet>` (e.g. `lib/x86_64-linux-gnu`), so
  `$PREFIX/lib` alone finds neither `libplacebo.so` nor `libplacebo.pc`. Paths are discovered, not
  assumed.

## Locally

```sh
sudo apt-get install -y build-essential cmake meson ninja-build pkg-config nasm yasm \
  libvulkan-dev glslang-dev liblcms2-dev libxxhash-dev libunwind-dev python3-jinja2 \
  libdrm-dev libegl-dev libgles-dev libva-dev python3-pip
JOBS="$(nproc)" bash scripts/build-cb1.sh .build
```

The work directory argument is normalised to an absolute path (meson rejects a relative
`--prefix`). The script is re-runnable: it skips sources it already extracted, patches it already
applied, and libraries already installed in the prefix.

Artefacts land in `out/`: the patched `ffprobe`, the patched libav* libraries and headers,
libplacebo, the CB1 engine library and its headers, plus `SHA256SUMS`. The script verifies each
download against the digests above and stops on a mismatch; it also compiles the exact
`AVDOVIDmData` probe CB1's CMake uses, so a tree CB1 would reject fails here instead of later.

## In CI

`.github/workflows/build-cb1.yml` runs the same script on `ubuntu-24.04` (on pull requests and on
pushes to `main` touching `CB1/**`, `scripts/**` or the workflow, plus manual dispatch) and
uploads `out/` as the `cb1-engine-linux-x64` artefact.

## Verification

Beyond producing files, the build is checked end to end:

- `ffprobe` from `out/bin` runs and reads DV content;
- the `AVDOVIDmData` probe compiles against the installed headers;
- libplacebo in `out/lib` exports the CB1 entry points (`pl_cb1_dovi_reference_abi`,
  `pl_shader_dovi_reconstruct`, `pl_hdr_metadata_from_dovi_rpu`);
- the engine library exports its public API (`dvbridge_create`, `dvbridge_prepare`,
  `dvbridge_commit`, `dvbridge_frame_area`, …), and a program linking `out/lib` gets a valid
  context back from `dvbridge_create()`.

## What this does not produce

An image or a player. CB1 needs a graphics context (GLES/EGL), GPU images and an HDMI output to
the display, and it is consumed by Kodi's render path: what is built here is a build input for
that player, together with the metadata-capable FFmpeg libraries. Building the LibreELEC image
itself remains the project's own release process (`sources.tar.zst` + `vendor-inputs.tar.zst`).
