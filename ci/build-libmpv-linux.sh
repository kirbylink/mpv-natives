#!/bin/bash -e
set -e
# (The shebang -e is not honored when the workflow invokes us via `bash file`,
# so set -e is repeated here to guarantee fail-fast regardless of caller.)
#
# Build a single self-contained libmpv.so for Linux x86_64 (native, no cross
# file, no lipo - the easiest of the three platforms). The workflow runs it on
# an ubuntu runner and uploads the result.
#
# Recipe: every dependency is built STATIC and linked into the one .so (same
# approach as ci/build-libmpv-mingw64.sh and ci/build-libmpv-macos.sh). glibc,
# libpthread, libdl, libm, libiconv and zlib are provided by the distro and
# linked dynamically - the resulting .so depends only on the system libraries.
#
# Differences vs macOS/Windows (Linux-only):
#   - libass is a hard mpv dependency and needs a font provider. macOS uses
#     CoreText, Windows uses DirectWrite, Linux uses fontconfig - so fontconfig
#     (and its XML backend, expat) are additional deps here. harfbuzz and
#     freetype are built without the fontconfig provider so the only font
#     stack is the one we link in.
#   - gl is the plain GL render-API support (no X11/Wayland context backend),
#     which jlibmpv's externally supplied OpenGL context (JOGL) consumes via
#     the mpv render API. No vo is built at all (cplayer=false).
#   - alsa is the audio output (no PulseAudio/JACK/OSS).
#
# All third-party sources are pinned to the latest stable tag that existed on
# the mpv v0.41.0 release date (2025-12-21), so a rebuild reproduces the same
# binary instead of drifting to git HEAD.

prefix_dir=$PWD/linux_prefix
mkdir -p "$prefix_dir"

wget="wget -nc --progress=bar:force"

export CC=gcc
export CXX=g++
export AR=ar
export NM=nm
export RANLIB=ranlib

export CFLAGS="-O2 -pipe -Wall"
export LDFLAGS=""

# Prefix for the static deps we build ourselves, added additively so the
# system pkg-config files (zlib, ...) are still visible.
export PKG_CONFIG_PATH="$prefix_dir/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# --- Pinned dependency versions -------------------------------------------
# Latest stable tag on or before the mpv v0.41.0 release (2025-12-21).
FFMPEG_VER=n8.0.1
DAV1D_VER=1.5.2
LIBPLACEBO_VER=v7.351.0
LIBASS_VER=0.17.4
LCMS2_VER=lcms2.17
FREETYPE_VER=2.14.1
FRIBIDI_VER=1.0.16
HARFBUZZ_VER=12.2.0
FONTCONFIG_VER=2.16.2
EXPAT_VER=R_2_7_3
ALSA_VER=v1.2.15

# Static everywhere: every dependency becomes a .a archive that gets linked
# into the single libmpv.so. (mpv's own script ships shared libs instead.)
commonflags="--disable-shared --enable-static"

function builddir {
    [ -d "$1/builddir" ] && rm -rf "$1/builddir"
    mkdir -p "$1/builddir"
    pushd "$1/builddir"
}

function makeplusinstall {
    if [ -f build.ninja ]; then
        ninja
        ninja install
    else
        make -j$(nproc)
        make install
    fi
}

function gettar {
    local name="${1##*/}"
    [ -d "${name%%.*}" ] && return 0
    $wget "$1"
    tar -xaf "$name"
}

# Clone a git dependency at a pinned tag (shallow, tag-checked-out).
# Submodules are fetched shallow too: libplacebo needs its bundled `glad`.
function gitpin {
    local url=$1 dest=$2 tag=$3
    [ -d "$dest" ] || git clone --depth=1 --branch "$tag" \
        --recurse-submodules --shallow-submodules "$url" "$dest"
    pushd "$dest"
    git checkout --quiet "$tag"
    popd
}

function build_if_missing {
    local name=${1//-/_}
    local mark_var=_${name}_mark
    local mark_file=$prefix_dir/${!mark_var}
    [ -e "$mark_file" ] && return 0
    echo "::group::Building $1"
    _$name
    echo "::endgroup::"
    if [ ! -e "$mark_file" ]; then
        echo "Error: Build of $1 completed but $mark_file was not created."
        return 2
    fi
}

## mpv's dependencies (all static; glibc/zlib/libiconv come from the system)

_expat () {
    gitpin https://github.com/libexpat/libexpat.git expat "$EXPAT_VER"
    # The tag places the CMake project one level down (expat/expat/).
    pushd expat/expat
    cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix_dir" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_EXAMPLES=OFF -DBUILD_TESTS=OFF -DBUILD_TOOLS=OFF
    cmake --build build -j$(nproc)
    cmake --install build
    popd
}
_expat_mark=lib/libexpat.a

_alsa () {
    gitpin https://github.com/alsa-project/alsa-lib.git alsa-lib "$ALSA_VER"
    builddir alsa-lib
    # alsa-lib ships autotools inputs but no generated configure; generate it
    # in the source tree (we build out-of-tree from ../). -fPIC is required
    # because the static archive is linked into the shared libmpv.so, and
    # alsa's configure only adds -fPIC for shared builds.
    ( cd .. && autoreconf -fi )
    # --with-configdir pins the ALSA_CONFIG_DIR compile-time default to the
    # canonical system path instead of our build prefix. alsa-lib looks up its
    # config at this path at runtime (env ALSA_CONFIG_DIR / ALSA_CONFIG_PATH
    # override); leaving it at $prefix_dir/share/alsa makes snd_pcm_open("default")
    # fail on any machine that does not carry that build path.
    CFLAGS="$CFLAGS -fPIC" ../configure --prefix="$prefix_dir" \
        --with-configdir=/usr/share/alsa $commonflags
    makeplusinstall
    popd
}
_alsa_mark=lib/libasound.a

_fontconfig () {
    gitpin https://github.com/fontconfig/fontconfig.git fontconfig "$FONTCONFIG_VER"
    builddir fontconfig
    # expat is the XML backend (our static build); no tests/tools/nls. freetype
    # resolves to our own static build via PKG_CONFIG_PATH (we link it into
    # libmpv, not fc's system one).
    #
    # Leave the default prefix (do NOT pin sysconfdir=/etc): the config paths
    # compiled into libfontconfig (FONTCONFIG_PATH/CONFIGDIR/FC_CACHEDIR) point
    # at the build prefix, which does not exist on the target machine. That is
    # harmless - when fontconfig finds no config file at the compiled-in path it
    # falls back to its built-in default config, which scans /usr/share/fonts
    # and /usr/local/share/fonts. So libass's font lookup works on any standard
    # Linux box without env vars, and `make install` stays inside the prefix
    # (no root needed). Pinning sysconfdir=/etc would instead make the build
    # try to install its conf files into the real /etc/fonts and fail.
    meson setup .. --buildtype release -Dprefix="$prefix_dir" -Dlibdir=lib \
        -Dxml-backend=expat -Dtests=disabled -Dtools=disabled -Dnls=disabled \
        -Ddefault_library=static
    makeplusinstall
    popd
}
_fontconfig_mark=lib/libfontconfig.a

_dav1d () {
    gitpin https://code.videolan.org/videolan/dav1d.git dav1d "$DAV1D_VER"
    builddir dav1d
    meson setup .. --buildtype release -Dprefix="$prefix_dir" -Dlibdir=lib \
        -Denable_{tools,tests}=false -Ddefault_library=static
    makeplusinstall
    popd
}
_dav1d_mark=lib/libdav1d.a

_lcms2 () {
    gitpin https://github.com/mm2/Little-CMS.git lcms2 "$LCMS2_VER"
    builddir lcms2
    meson setup .. --buildtype release -Dprefix="$prefix_dir" -Dlibdir=lib \
        -Dtests=disabled -Dutils=false -Ddefault_library=static
    makeplusinstall
    popd
}
_lcms2_mark=lib/liblcms2.a

_ffmpeg () {
    gitpin https://github.com/FFmpeg/FFmpeg.git ffmpeg "$FFMPEG_VER"
    builddir ffmpeg
    # --enable-pic: the static archives are linked into the shared
    # libmpv.so (ffmpeg's configure does not force PIC for static builds).
    args=(
        --prefix="$prefix_dir" --pkg-config=pkg-config --target-os=linux
        --enable-gpl --enable-pic $commonflags
        --disable-{doc,programs}
        --enable-muxer=spdif --enable-encoder=mjpeg,png --enable-libdav1d
    )
    ../configure "${args[@]}"
    makeplusinstall
    popd
}
_ffmpeg_mark=lib/libavcodec.a

_freetype () {
    gettar "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VER}.tar.xz"
    builddir freetype-${FREETYPE_VER}
    # zlib stays (system lib); every other third-party provider is disabled.
    # harfbuzz off: we link our own static harfbuzz into libmpv, not FT's hook.
    meson setup .. --buildtype release -Dprefix="$prefix_dir" -Dlibdir=lib \
        -Dzlib=enabled -Dbrotli=disabled -Dbzip2=disabled -Dpng=disabled \
        -Dharfbuzz=disabled -Ddefault_library=static
    makeplusinstall
    popd
}
_freetype_mark=lib/libfreetype.a

_fribidi () {
    gettar "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VER}/fribidi-${FRIBIDI_VER}.tar.xz"
    builddir fribidi-${FRIBIDI_VER}
    meson setup .. --buildtype release -Dprefix="$prefix_dir" -Dlibdir=lib \
        -D{tests,docs}=false -Ddefault_library=static
    makeplusinstall
    popd
}
_fribidi_mark=lib/libfribidi.a

_harfbuzz () {
    gettar "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VER}/harfbuzz-${HARFBUZZ_VER}.tar.xz"
    builddir harfbuzz-${HARFBUZZ_VER}
    # icu off (an extra dep; harfbuzz shapes fine with built-in unicode data).
    # No freetype backend (matches macOS/Windows; the freetype_min_version in
    # harfbuzz is not needed - libass drives freetype itself for font loading).
    meson setup .. --buildtype release -Dprefix="$prefix_dir" -Dlibdir=lib \
        -Dtests=disabled -Dutilities=disabled -Dicu=disabled \
        -Dfreetype=disabled -Ddefault_library=static
    makeplusinstall
    popd
}
_harfbuzz_mark=lib/libharfbuzz.a

_libass () {
    gitpin https://github.com/libass/libass.git libass "$LIBASS_VER"
    builddir libass
    # fontconfig is the Linux font provider (system framework equivalent);
    # freetype and fribidi are auto-detected and resolve to our own static
    # builds via PKG_CONFIG_PATH. asm off for determinism.
    meson setup .. --buildtype release -Dprefix="$prefix_dir" -Dlibdir=lib \
        -Dfontconfig=enabled -Dasm=disabled -Dlibunibreak=disabled \
        -Ddefault_library=static
    makeplusinstall
    popd
}
_libass_mark=lib/libass.a

_libplacebo () {
    gitpin https://code.videolan.org/videolan/libplacebo.git libplacebo "$LIBPLACEBO_VER"
    builddir libplacebo
    # opengl enabled (the only renderer jlibmpv uses); vulkan/d3d11 off;
    # lcms/xxhash off. GL is resolved at runtime by libplacebo's glad loader,
    # so no libGL link is required.
    meson setup .. --buildtype release -Dprefix="$prefix_dir" -Dlibdir=lib \
        -Ddemos=false -Dopengl=enabled -Dd3d11=disabled \
        -Dvulkan=disabled -Dlcms=disabled -Dxxhash=disabled \
        -Ddefault_library=static
    makeplusinstall
    popd
}
_libplacebo_mark=lib/libplacebo.a

# Group A: no intra-prefix deps (freetype is built with harfbuzz off, so it
# needs nothing we build here - only system zlib).
for x in expat alsa freetype fribidi dav1d lcms2; do
    build_if_missing $x
done
# Group B: depend on group A (fontconfig/libass need freetype2.pc, libass
# needs harfbuzz+fontconfig+fribidi, ffmpeg needs dav1d+lcms2).
for x in ffmpeg fontconfig harfbuzz libass libplacebo; do
    build_if_missing $x
done

## mpv

build=linux_build
rm -rf $build

# libmpv itself is the ONE shared object (default_library=shared), linked
# against the static dependency archives built above. No CLI player, no tests,
# no lua/javascript, no vulkan. plain-gl is the OpenGL render-API support
# (no X11/Wayland context backend - jlibmpv supplies the GL context via JOGL).
# alsa is the audio output.
meson setup $build \
  --buildtype release -Dstrip=true \
  -Ddefault_library=shared \
  -Dlibmpv=true \
  -Dcplayer=false \
  -Dtests=false \
  -Dlua=disabled \
  -Djavascript=disabled \
  -Dshaderc=disabled \
  -Dspirv-cross=disabled \
  -Dvulkan=disabled \
  -Dgl=enabled -Dplain-gl=enabled \
  -Dgl-x11=disabled -Degl=disabled -Ddrm=disabled -Dwayland=disabled \
  -Dalsa=enabled -Dpulse=disabled -Djack=disabled -Doss-audio=disabled \
  -Dx11=disabled -Dx11-clipboard=disabled

meson compile -C $build

## Collect the self-contained .so

mkdir -p artifact
# meson produces libmpv.so -> libmpv.so.2 -> libmpv.so.2.0.0; -type f keeps
# only the real (versioned) object, skipping the two symlinks.
LIBMPV_SO=$(find $build -maxdepth 1 -type f -name 'libmpv.so*' | sort -V | tail -n 1)
[ -n "$LIBMPV_SO" ] || { echo "ERROR: libmpv.so not found in $build"; ls -l $build; exit 1; }
# jlibmpv loads libmpv.so (no version suffix), so copy the versioned object
# under the versionless name.
cp -pv "$LIBMPV_SO" artifact/libmpv.so
# The build releases with --buildtype release but the object still carries its
# debug sections (~110 MB here: the whole ffmpeg tree's DWARF), so strip it
# explicitly (like the windows build) to get a small distributable.
strip --strip-all artifact/libmpv.so

echo "=== artifact contents ==="
ls -l artifact
echo "=== libmpv.so dynamic dependencies (should be system libs only) ==="
ldd artifact/libmpv.so || true