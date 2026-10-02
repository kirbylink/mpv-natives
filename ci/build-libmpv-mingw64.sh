#!/bin/bash -e
set -e
# (The shebang -e is not honored when the workflow invokes us via `bash file`,
# so set -e is repeated here to guarantee fail-fast regardless of caller.)
#
# Build a single self-contained libmpv-2.dll for Windows x86_64 (MinGW-w64).
#
# Recipe adapted from mpv's own ci/build-mingw64.sh, with the key difference
# that every dependency is built STATIC and libmpv itself is the only shared
# object, linked against the static dependency archives with a static CRT.
# The result is ONE DLL that depends only on Windows system libraries
# (kernel32, user32, gdi32, ...), no runtime dependency closure to ship.
#
# This mirrors the proven build behind the ben-ic/libmpv-win64 reference
# (single self-contained mpv-2.dll), ported from Clang/MSVC (/MT) to MinGW-w64.
#
# Vulkan / shaderc / SPIRV-Cross are intentionally NOT built: jlibmpv renders
# through an externally supplied OpenGL context (JOGL) and never uses the
# Vulkan video backend, so shipping it is dead weight and the source of the
# most flaky dependency builds.
#
# All third-party sources are pinned to the latest stable tag that existed on
# the mpv v0.41.0 release date (2025-12-21), so a rebuild reproduces the same
# binary instead of drifting to git HEAD.

# The mpv source tree is the current working directory (checked out by CI at
# MPV_REF). Everything is built next to it under mingw_prefix/.
prefix_dir=$PWD/mingw_prefix
mkdir -p "$prefix_dir"
ln -snf . "$prefix_dir/usr"
ln -snf . "$prefix_dir/local"

wget="wget -nc --progress=bar:force --tries=3 --timeout=60 --waitretry=5"

# -posix is Ubuntu's variant with pthreads support
export CC=$TARGET-gcc-posix
export AS=$TARGET-gcc-posix
export CXX=$TARGET-g++-posix
export AR=$TARGET-ar
export NM=$TARGET-nm
export RANLIB=$TARGET-ranlib

export CFLAGS="-O2 -pipe -Wall"
export LDFLAGS="-fstack-protector-strong"

# anything that uses pkg-config
export PKG_CONFIG_SYSROOT_DIR="$prefix_dir"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig"

# --- Pinned dependency versions -------------------------------------------
# Centralized in ci/versions.env (single source of truth shared with the other
# platforms and with CI). Bump mpv + deps there.
. "$(dirname "$0")/versions.env"

# Static everywhere: every dependency becomes a .a archive that gets linked
# into the single libmpv-2.dll. (mpv's own script ships shared .dlls instead.)
commonflags="--disable-shared --enable-static"

# meson cross file. No rust binary: mpv v0.41.0 has no Rust sources, and
# lua/javascript are disabled below, so the toolchain needs nothing but
# the C/C++ cross compilers, a linker, and wine only if meson runs a host
# executable (it does not for a libmpv-only, no-tests build).
fam=x86_64
cat >"$prefix_dir/crossfile" <<EOF
[built-in options]
buildtype = 'release'
wrap_mode = 'nodownload'
[binaries]
c = ['ccache', '${CC}']
cpp = ['ccache', '${CXX}']
ar = '${AR}'
strip = '${TARGET}-strip'
pkgconfig = 'pkg-config'
pkg-config = 'pkg-config'
windres = '${TARGET}-windres'
dlltool = '${TARGET}-dlltool'
nasm = 'nasm'
exe_wrapper = 'wine'
[host_machine]
system = 'windows'
cpu_family = '${fam}'
cpu = '${TARGET%%-*}'
endian = 'little'
EOF

function builddir {
    [ -d "$1/builddir" ] && rm -rf "$1/builddir"
    mkdir -p "$1/builddir"
    pushd "$1/builddir"
}

function makeplusinstall {
    if [ -f build.ninja ]; then
        ninja
        DESTDIR="$prefix_dir" ninja install
    else
        make -j$(nproc)
        make DESTDIR="$prefix_dir" install
    fi
}

function gettar {
    local name="${1##*/}"
    [ -d "${name%%.*}" ] && return 0
    $wget "$1"
    tar -xaf "$name"
}

# Clone a git dependency at a pinned tag (shallow, tag-checked-out).
# Submodules are fetched shallow too: libplacebo needs its bundled `glad`,
# ffmpeg/dav1d/others carry submodules needed for the build.
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


## mpv's dependencies (all static)

_iconv () {
    gettar "https://ftpmirror.gnu.org/gnu/libiconv/libiconv-${ICONV_VER}.tar.gz"
    builddir libiconv-${ICONV_VER}
    ../configure --host=$TARGET $commonflags
    makeplusinstall
    popd
}
# static import-lib placeholder: libiconv still ships a .dll.a even when the
# code is compiled static for linking convenience; keep mpv's mark file.
_iconv_mark=lib/libiconv.a

_zlib () {
    gettar "https://zlib.net/fossils/zlib-${ZLIB_VER}.tar.gz"
    pushd zlib-${ZLIB_VER}
    make -fwin32/Makefile.gcc clean
    make -fwin32/Makefile.gcc PREFIX=$TARGET- CC="$CC" SHARED_MODE=0 \
        DESTDIR="$prefix_dir" install \
        BINARY_PATH=/bin INCLUDE_PATH=/include LIBRARY_PATH=/lib
    popd
}
# static build yields libz.a (SHARED_MODE=0); no libz.dll.a
_zlib_mark=lib/libz.a

_dav1d () {
    gitpin https://code.videolan.org/videolan/dav1d.git dav1d "$DAV1D_VER"
    builddir dav1d
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Denable_{tools,tests}=false -Ddefault_library=static
    makeplusinstall
    popd
}
_dav1d_mark=lib/libdav1d.a

_lcms2 () {
    gitpin https://github.com/mm2/Little-CMS.git lcms2 "$LCMS2_VER"
    builddir lcms2
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Dtests=disabled -Dutils=false -Ddefault_library=static
    makeplusinstall
    popd
}
_lcms2_mark=lib/liblcms2.a

_ffmpeg () {
    gitpin https://github.com/FFmpeg/FFmpeg.git ffmpeg "$FFMPEG_VER"
    builddir ffmpeg
    # No --enable-gpl: we only need LGPL-available features (see the linux
    # script for the rationale) so the resulting libmpv stays LGPL and can be
    # embedded via JNA without taint.
    local args=(
        --pkg-config=pkg-config --target-os=mingw32
        --enable-cross-compile --cross-prefix=$TARGET- --arch=${TARGET%%-*}
        --cc="$CC" --cxx="$CXX" $commonflags
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
    meson setup .. --cross-file "$prefix_dir/crossfile" -Ddefault_library=static
    makeplusinstall
    popd
}
_freetype_mark=lib/libfreetype.a

_fribidi () {
    gettar "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VER}/fribidi-${FRIBIDI_VER}.tar.xz"
    builddir fribidi-${FRIBIDI_VER}
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -D{tests,docs}=false -Ddefault_library=static
    makeplusinstall
    popd
}
_fribidi_mark=lib/libfribidi.a

_harfbuzz () {
    gettar "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VER}/harfbuzz-${HARFBUZZ_VER}.tar.xz"
    builddir harfbuzz-${HARFBUZZ_VER}
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Dtests=disabled -Ddefault_library=static
    makeplusinstall
    popd
}
_harfbuzz_mark=lib/libharfbuzz.a

_libass () {
    gitpin https://github.com/libass/libass.git libass "$LIBASS_VER"
    builddir libass
    meson setup .. --cross-file "$prefix_dir/crossfile" -Ddefault_library=static
    makeplusinstall
    popd
}
_libass_mark=lib/libass.a

for x in iconv zlib dav1d lcms2; do
    build_if_missing $x
done
for x in ffmpeg freetype fribidi harfbuzz libass; do
    build_if_missing $x
done
_libplacebo () {
    gitpin https://code.videolan.org/videolan/libplacebo.git libplacebo "$LIBPLACEBO_VER"
    builddir libplacebo
    # opengl enabled (the only renderer jlibmpv uses); d3d11/lcms off
    meson setup .. --cross-file "$prefix_dir/crossfile" \
        -Ddemos=false -Dopengl=enabled -Dd3d11=disabled -Dlcms=disabled \
        -Ddefault_library=static
    makeplusinstall
    popd
}
_libplacebo_mark=lib/libplacebo.a
build_if_missing libplacebo

## mpv

CFLAGS+=" -I'$prefix_dir/include'"
LDFLAGS+=" -L'$prefix_dir/lib'"
# Static CRT: fold libgcc / libstdc++ / winpthread into libmpv-2.dll so the
# resulting DLL has no MinGW runtime DLL dependencies (the /MT equivalent).
# -lstdc++ is added explicitly: libplacebo is C++ but libmpv is a C target, so
# meson's C link driver does not pull in the C++ runtime on its own. These
# flags land inside meson's --start-group/--end-group, so ordering is safe.
LDFLAGS+=" -static -static-libgcc -static-libstdc++ -lstdc++"
export CFLAGS LDFLAGS

build=mingw_build
rm -rf $build

# libmpv itself is the ONE shared object (default_library=shared), linked
# against the static dependency archives built above. No CLI player, no tests,
# no lua/javascript, no vulkan/shaderc. OpenGL stays (default gl=enabled).
meson setup $build --cross-file "$prefix_dir/crossfile" \
  --buildtype release \
  -Ddefault_library=shared \
  -Dlibmpv=true \
  -Dgpl=false \
  -Dcplayer=false \
  -Dtests=false \
  -Dlua=disabled \
  -Djavascript=disabled \
  -Dshaderc=disabled \
  -Dspirv-cross=disabled \
  -Dvulkan=disabled \
  -Dd3d11=disabled
meson compile -C $build

## Collect the self-contained DLL

mkdir -p artifact
LIBMPV_DLL=$(find $build -maxdepth 1 -name 'libmpv-*.dll' | head -n 1)
[ -n "$LIBMPV_DLL" ] || { echo "ERROR: libmpv DLL not found in $build"; ls -l $build; exit 1; }
cp -pv "$LIBMPV_DLL" artifact/
# buildtype=release emits DWARF .debug_* sections even for MinGW; for a
# distributable native we strip them out (~130 MB) so only the code/data
# sections remain.
"$TARGET-strip" --strip-all "artifact/$(basename "$LIBMPV_DLL")"
# The artifact is the single self-contained DLL only. No public headers
# (jlibmpv loads it via JNA at runtime and never compiles against it) and no
# import library - keeping it a single binary stays consistent with the
# macOS build (one libmpv.dylib) and the Linux build (one libmpv.so).

echo "=== artifact contents ==="
ls -l artifact
echo "=== libmpv-2.dll import dependencies (should be Windows system DLLs only) ==="
"$TARGET-objdump" -p "artifact/$(basename "$LIBMPV_DLL")" | awk '/DLL Name/{print $3}' || true