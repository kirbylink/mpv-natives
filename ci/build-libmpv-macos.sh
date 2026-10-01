#!/bin/bash -e
set -e
# (The shebang -e is not honored when the workflow invokes us via `bash file`,
# so set -e is repeated here to guarantee fail-fast regardless of caller.)
#
# Build a single self-contained libmpv dylib for macOS for one architecture
# (arm64 natively, or x86_64 via clang --target=x86_64-apple-darwin).
# The workflow runs this script twice on one arm64 runner and merges the two
# dylibs into a universal binary with lipo. (GitHub's macOS runners are all
# arm64 now, so x86_64 must be cross-compiled.)
#
# Recipe: every dependency is built STATIC and linked into the one dylib
# (same approach as ci/build-libmpv-mingw64.sh for Windows). No iconv (macOS
# ships one), no zlib (macOS ships one, universal), no icu (harfbuzz built
# without it - the runner's brew icu is arm64-only and must not leak into
# the x86_64 slice). Vulkan is intentionally NOT built: jlibmpv renders
# through an externally supplied OpenGL context (JOGL + render API).
# CoreAudio is the audio output; VideoToolbox provides hardware decode.
#
# All third-party sources are pinned to the latest stable tag that existed on
# the mpv v0.41.0 release date (2025-12-21), so a rebuild reproduces the same
# binary instead of drifting to git HEAD.

# Target architecture: arm64 (native) or x86_64 (cross).
ARCH=${ARCH:-arm64}

# The mpv source tree is the current working directory (checked out by CI at
# MPV_REF). Everything is built next to it under macos_prefix-<arch>/.
prefix_dir=$PWD/macos_prefix-$ARCH
mkdir -p "$prefix_dir"

wget="wget -nc --progress=bar:force"

TARGET_FLAG=""
if [ "$ARCH" = "x86_64" ]; then
    TARGET_FLAG="--target=x86_64-apple-darwin"
fi

export CC="cc${TARGET_FLAG:+ $TARGET_FLAG}"
export CXX="c++${TARGET_FLAG:+ $TARGET_FLAG}"
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

# Static everywhere: every dependency becomes a .a archive that gets linked
# into the single libmpv dylib. (mpv's own script ships shared libs instead.)
commonflags="--disable-shared --enable-static"

# Meson cross file for the x86_64 slice. arm64 is a plain native build.
MESON_EXTRA=""
if [ "$ARCH" = "x86_64" ]; then
    cat >"$prefix_dir/crossfile" <<EOF
[built-in options]
buildtype = 'release'
[binaries]
c = ['cc', '--target=x86_64-apple-darwin']
cpp = ['c++', '--target=x86_64-apple-darwin']
objc = ['cc', '--target=x86_64-apple-darwin']
ar = 'ar'
strip = 'strip'
pkgconfig = 'pkg-config'
pkg-config = 'pkg-config'
nasm = 'nasm'
[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
    MESON_EXTRA="--cross-file $prefix_dir/crossfile"
fi

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
        make -j$(sysctl -n hw.ncpu)
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

## mpv's dependencies (all static; macOS ships zlib and iconv in the system)

_dav1d () {
    gitpin https://code.videolan.org/videolan/dav1d.git dav1d "$DAV1D_VER"
    builddir dav1d
    meson setup .. $MESON_EXTRA --buildtype release -Dprefix="$prefix_dir" \
        -Denable_{tools,tests}=false -Ddefault_library=static
    makeplusinstall
    popd
}
_dav1d_mark=lib/libdav1d.a

_lcms2 () {
    gitpin https://github.com/mm2/Little-CMS.git lcms2 "$LCMS2_VER"
    builddir lcms2
    meson setup .. $MESON_EXTRA --buildtype release -Dprefix="$prefix_dir" \
        -Dtests=disabled -Dutils=false -Ddefault_library=static
    makeplusinstall
    popd
}
_lcms2_mark=lib/liblcms2.a

_ffmpeg () {
    gitpin https://github.com/FFmpeg/FFmpeg.git ffmpeg "$FFMPEG_VER"
    builddir ffmpeg
    # --arch is explicit: ffmpeg would otherwise auto-detect aarch64 from
    # uname -m on the runner even for the cross-compiled x86_64 slice.
    args=(
        --prefix="$prefix_dir" --pkg-config=pkg-config --target-os=darwin
        --arch="$ARCH"
        --enable-gpl $commonflags
        --cc="$CC" --cxx="$CXX"
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
    # zlib stays (universal system lib); every other third-party provider is
    # disabled so no arm64-only brew package can leak into the x86_64 slice.
    # harfbuzz off: we link our own static harfbuzz into libmpv, not FT's
    # hook (and it would pull brew's build in again).
    meson setup .. $MESON_EXTRA --buildtype release -Dprefix="$prefix_dir" \
        -Dzlib=enabled -Dbrotli=disabled -Dbzip2=disabled -Dpng=disabled \
        -Dharfbuzz=disabled -Ddefault_library=static
    makeplusinstall
    popd
}
_freetype_mark=lib/libfreetype.a

_fribidi () {
    gettar "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VER}/fribidi-${FRIBIDI_VER}.tar.xz"
    builddir fribidi-${FRIBIDI_VER}
    meson setup .. $MESON_EXTRA --buildtype release -Dprefix="$prefix_dir" \
        -D{tests,docs}=false -Ddefault_library=static
    makeplusinstall
    popd
}
_fribidi_mark=lib/libfribidi.a

_harfbuzz () {
    gettar "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VER}/harfbuzz-${HARFBUZZ_VER}.tar.xz"
    builddir harfbuzz-${HARFBUZZ_VER}
    # icu disabled: the runner's brew icu is arm64-only and would poison the
    # x86_64 slice; harfbuzz shapes fine without it (built-in unicode data).
    # coretext is the Apple font provider (system framework, universal).
    meson setup .. $MESON_EXTRA --buildtype release -Dprefix="$prefix_dir" \
        -Dtests=disabled -Dutilities=disabled -Dicu=disabled \
        -Dcoretext=enabled -Ddefault_library=static
    makeplusinstall
    popd
}
_harfbuzz_mark=lib/libharfbuzz.a

_libass () {
    gitpin https://github.com/libass/libass.git libass "$LIBASS_VER"
    builddir libass
    # CoreText is the system font provider (framework, universal); fontconfig
    # is off so the runner's arm64-only brew package can't leak into the
    # x86_64 slice. asm off for determinism across both slices.
    meson setup .. $MESON_EXTRA --buildtype release -Dprefix="$prefix_dir" \
        -Dfontconfig=disabled -Dcoretext=enabled -Dasm=disabled \
        -Ddefault_library=static
    makeplusinstall
    popd
}
_libass_mark=lib/libass.a

for x in dav1d lcms2; do
    build_if_missing $x
done
for x in ffmpeg freetype fribidi harfbuzz libass; do
    build_if_missing $x
done
_libplacebo () {
    gitpin https://code.videolan.org/videolan/libplacebo.git libplacebo "$LIBPLACEBO_VER"
    builddir libplacebo
    # opengl enabled (the only renderer jlibmpv uses); vulkan/d3d11 off;
# xxhash off (optional) so the arm64-only brew package can't leak into the
# x86_64 slice.
    meson setup .. $MESON_EXTRA --buildtype release -Dprefix="$prefix_dir" \
        -Ddemos=false -Dopengl=enabled -Dd3d11=disabled \
        -Dvulkan=disabled -Dlcms=disabled -Dxxhash=disabled \
        -Ddefault_library=static
    makeplusinstall
    popd
}
_libplacebo_mark=lib/libplacebo.a
build_if_missing libplacebo

## mpv

build=macos_build-$ARCH
rm -rf $build

# libmpv itself is the ONE shared object (default_library=shared), linked
# against the static dependency archives built above. No CLI player, no
# tests, no lua/javascript, no vulkan. OpenGL render API stays (cocoa +
# gl-cocoa are the macOS backend for it); coreaudio is the audio output;
# videotoolbox gives hardware decode.
meson setup $build $MESON_EXTRA \
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
  -Dcocoa=enabled \
  -Dgl-cocoa=enabled \
  -Dcoreaudio=enabled \
  -Dvideotoolbox-gl=enabled
meson compile -C $build

## Collect the self-contained dylib

mkdir -p artifact-$ARCH
LIBMPV_DYLIB=$(find $build -maxdepth 1 -name "libmpv.2.dylib" | head -n 1)
[ -n "$LIBMPV_DYLIB" ] || { echo "ERROR: libmpv dylib not found in $build"; ls -l $build; exit 1; }
cp -pv "$LIBMPV_DYLIB" artifact-$ARCH/

echo "=== artifact-$ARCH contents ==="
ls -l artifact-$ARCH
echo "=== libmpv-2.dylib ($ARCH) load commands (should be system frameworks only) ==="
otool -arch $ARCH "artifact-$ARCH/libmpv.2.dylib" -L