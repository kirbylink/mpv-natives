# mpv-natives

Self-built [libmpv](https://mpv.io/manual/#libmpv) native binaries for
[jlibmpv](https://github.com/kirbylink/jlibmpv), the Java/JNA wrapper library.

## Why this repository exists

`jlibmpv` is 100% MIT and deliberately does not bundle any native binaries
(libmpv is GPL-licensed). End users who want a drop-in native they can point
`mpv.libmpv.path` at (or that a `RemoteNativeLocator` can download) find them
here, as versioned GitHub release assets.

- **Pinned version:** mpv `v0.41.0` — the exact client API (131077) the
  jlibmpv JNA bindings are validated against. A libmpv update means bumping
  `MPV_REF` (and the affected dependency pins) in `ci/versions.env` — the
  single source of truth for every version in this repository.
- **Build source:** the mpv source tree is checked out at that tag by
  GitHub Actions and built with the vendored scripts in `ci/`
  (`build-libmpv-mingw64.sh`, `build-libmpv-macos.sh`, `build-libmpv-linux.sh`).
  No mpv source or third-party binaries are stored in this repository.

## Releases

Each platform produces a single self-contained library file plus a combined
`checksums.txt` (SHA-256) for verification. Assets are published by pushing a
tag of the form `v<mpv-version>` (e.g. `v0.41.0`), which triggers
`release.yml`:

| Asset | Contents |
|---|---|
| `mpv-natives-windows-x86_64-<ver>.dll` | `libmpv-2.dll` (all dependencies statically linked, mingw64 build) |
| `mpv-natives-macos-universal-<ver>.dylib` | `libmpv.dylib` (universal arm64 + x86_64, all dependencies statically linked) |
| `mpv-natives-linux-x86_64-<ver>.so` | `libmpv.so` (all dependencies statically linked, native x86_64 build) |

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

The artifacts are built from mpv (GPL-3.0-or-later) and its dependencies
(LGPL/GPL) and are distributed under those licenses. See [LICENSE](LICENSE)
for the repository's license terms.