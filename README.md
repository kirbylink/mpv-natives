# mpv-natives

![Release](https://img.shields.io/github/v/release/kirbylink/mpv-natives)
![mpv v0.41.0](https://img.shields.io/badge/mpv-v0.41.0-informational)
![Downloads (latest release)](https://img.shields.io/github/downloads/kirbylink/mpv-natives/latest/total)
![Downloads (all releases)](https://img.shields.io/github/downloads/kirbylink/mpv-natives/total)
![License](https://img.shields.io/github/license/kirbylink/mpv-natives)

Self-built [libmpv](https://mpv.io/manual/#libmpv) native binaries for
Linux, macOS and Windows. They are built for
[jlibmpv](https://github.com/kirbylink/jlibmpv), the Java/JNA wrapper
library, but since they are plain library files with no jlibmpv-specific
content, they can be loaded from any language or binding.

## Why this repository exists

The official mpv releases do not ship a standalone `libmpv` — it is only
embedded in the platform packages — and the community daily builds ship
rolling versions with debug symbols intact (the Windows `libmpv-2.dll`
alone is ~220 MB, versus ~35 MB stripped here). For a library that
applications can pin as a dependency, this repository provides a pinned,
stripped, self-contained `libmpv`, reproducible from its tag alone.

The artifacts target mpv's LGPL-2.1-or-later license path (`-Dgpl=false`,
ffmpeg without `--enable-gpl`), so the resulting `libmpv` can be embedded
into arbitrary — including closed-source — applications that load it
in-process, without the GPL's copyleft obligations reaching into their code.

- **Pinned version:** mpv `v0.41.0` (client API 131077) — the exact,
  stable revision every release asset is built from. A libmpv update means
  bumping `MPV_REF` (and the affected dependency pins) in
  `ci/versions.env` — the single source of truth for every version in this
  repository.
- **Build source:** the mpv source tree is checked out at that tag by
  GitHub Actions and built with the vendored scripts in `ci/`
  (`build-libmpv-mingw64.sh`, `build-libmpv-macos.sh`, `build-libmpv-linux.sh`).
  No mpv source or third-party binaries are stored in this repository.

## Releases

Each platform produces a single self-contained library file plus a combined
`checksums.txt` (SHA-256) for verification. Assets are published by pushing a
tag of the form `v<mpv-version>` (e.g. `v0.41.0`), which triggers
`release.yml`:

| Asset | Contents | Size |
|---|---|---|
| `mpv-natives-windows-x86_64-<ver>.dll` | `libmpv-2.dll` (all dependencies statically linked, mingw64 build) | ~35 MB |
| `mpv-natives-macos-universal-<ver>.dylib` | `libmpv.dylib` (universal arm64 + x86_64, all dependencies statically linked) | ~68 MB |
| `mpv-natives-linux-x86_64-<ver>.so` | `libmpv.so` (all dependencies statically linked, native x86_64 build) | ~35 MB |

Per-asset download counts of the latest release (the release page only
shows a combined total):

![windows x86_64](https://img.shields.io/github/downloads/kirbylink/mpv-natives/latest/mpv-natives-windows-x86_64-0.41.0.dll)
![macos universal](https://img.shields.io/github/downloads/kirbylink/mpv-natives/latest/mpv-natives-macos-universal-0.41.0.dylib)
![linux x86_64](https://img.shields.io/github/downloads/kirbylink/mpv-natives/latest/mpv-natives-linux-x86_64-0.41.0.so)

Each native is fully self-contained: every dependency (ffmpeg, libass,
libplacebo, harfbuzz, freetype, fribidi, …) is statically linked into the
single library together with the C/C++ runtime where needed. The library
depends only on the platform's system libraries, so there is no dependency
closure to ship alongside it — jlibmpv loads it at runtime via JNA and never
compiles against it, so no public headers are shipped.

Audio is the one area deliberately left to the OS stack: on Linux the
PipeWire / Pulse / ALSA libraries are linked dynamically (mirroring CoreAudio
on macOS and WASAPI on Windows), and mpv auto-probes them in the order
pipewire → pulse → alsa. On Linux the self-built `libmpv.so` additionally
removes the need for the distribution package (`libmpv1`), which lags behind in
codec support (dav1d/AV1, x264/x265): the pinned ffmpeg 8.0.1 guarantees the
full codec set on any recent glibc distribution.

## How to use with jlibmpv

1. Download the release asset for your platform (a single library file).
2. Point jlibmpv at it:
   `-Dmpv.libmpv.path=/path/to/mpv-natives-<platform>-<ver>.<ext>`.

   Or let a `RemoteNativeLocator` fetch it — the download URL is
   deterministic from (platform, mpv version):

   ```
   https://github.com/kirbylink/mpv-natives/releases/download/v<ver>/mpv-natives-<platform>-<ver>.<ext>
   ```

   where `<platform>` is `windows-x86_64` / `macos-universal` / `linux-x86_64`
   and `<ext>` is `dll` / `dylib` / `so` respectively.

## Building

Builds run on GitHub Actions. There is nothing to build locally.

- A **pull request** runs the three per-platform builds as the check.
- A **`v*` tag** builds all three and publishes the GitHub Release.
- **Manual** runs are available in the Actions tab.

## License

The release artifacts are built from mpv on its **LGPL-2.1-or-later** path
(`-Dgpl=false`) and from FFmpeg without `--enable-gpl`, so the resulting
`libmpv` is LGPL-2.1-or-later (the ffmpeg libraries inside are likewise
LGPL, with BSD-licensed components such as dav1d). Distributing an
application that loads one of these libraries is fine under any license;
the LGPL only requires that the user be able to replace the library with a
different build (which is exactly what `mpv.libmpv.path` allows) and that
you keep the library's license and source-available terms for the library
itself. If you use a GPL distribution instead, the GPL's obligations apply.

The build scripts and workflows in this repository are MIT-licensed. See
[LICENSE](LICENSE) for the repository's license terms.