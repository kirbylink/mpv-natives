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
  `MPV_REF` in the workflows.
- **Build source:** the mpv source tree is checked out at that tag by
  GitHub Actions and built with mpv's own CI scripts
  (`ci/build-mingw64.sh`, ...). No mpv source or third-party binaries are
  stored in this repository.

## Releases

Each platform build produces a zip with the native library (self-contained,
single file) and a `checksums.txt` (SHA-256) for verification.

| Asset | Contents |
|---|---|
| `mpv-natives-windows-x86_64-mpv-<ver>.zip` | `libmpv-2.dll` (all dependencies statically linked, mingw64 build) |
| `mpv-natives-macos-<arch>-mpv-<ver>.zip` | `libmpv.dylib` (in preparation) |

The Windows DLL is fully self-contained: every dependency (ffmpeg, libass,
libplacebo, harfbuzz, freetype, fribidi, …) is statically linked into
`libmpv-2.dll` together with a static C/C++ runtime. It depends only on
Windows system libraries, so there is no DLL closure to extract alongside it.

Linux users can normally use the distribution package (`apt install libmpv1`)
instead; a self-built Linux artifact is planned only if needed.

## How to use with jlibmpv

1. Download the release asset for your platform and extract it.
2. Point jlibmpv at the extracted `libmpv-2.dll` / `libmpv.dylib`:
   `-Dmpv.libmpv.path=/path/to/extracted/libmpv-2.dll`.

## Building

Builds run on GitHub Actions and are triggered by pushes to `main` or
manually (Actions tab). There is nothing to build locally.

## License

The artifacts are built from mpv (GPL-3.0-or-later) and its dependencies
(LGPL/GPL) and are distributed under those licenses. See [LICENSE](LICENSE)
for the repository's license terms.