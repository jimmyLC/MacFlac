# MacFlac

**Fast batch music → FLAC converter for macOS.**

Drop in any audio file (`mp3` / `m4a` / `wav` / `aiff` / `ape` / `wma` / `opus` / `ogg` / `dsf` / … or even a video) and get a `.flac` back. Several files convert at once, so a whole album takes seconds.

[繁體中文說明 →](README.zh-TW.md)

## Features

- 🚀 **Fast** — files convert in parallel (default: one per performance core, max 8). On an M-series Mac, 40 minutes of audio converts in about 1 second.
- 🎵 **Almost anything in** — MP3, AAC/M4A, WAV, AIFF, ALAC, APE, WavPack, WMA, Opus, Ogg, DSD, AC3/DTS, and the audio track of video files (mkv / mp4 / mov / ts …).
- 🎚 **Bit-depth aware** — 16-bit stays 16-bit, 24-bit / float sources become 24-bit, lossy sources decode to 16-bit.
- 🏷 **Tags and cover art kept** — title/artist/album tags and embedded JPEG/PNG covers carry over.
- 🛟 **Safe** — writes to a private temp folder and only renames into place after the result is verified (length and audio stream); originals are never touched.
- 🗂 **Batch queue** — drag in files or whole folders, per-file progress, Finder reveal, retry.
- 🌐 English / Traditional Chinese UI, native SwiftUI (Liquid Glass on macOS 26).
- ⌨️ CLI included.

> FLAC is lossless, but it can't restore detail a lossy source (MP3, AAC…) already threw away. Converting those gives a larger file with the same sound.

Compression level (Fastest / Standard / Smallest) only trades speed against file size — the audio is identical.

## Requirements

- Apple Silicon Mac, macOS 13 or newer
- [ffmpeg](https://ffmpeg.org) — `brew install ffmpeg` (the app can run this for you on first launch)

## Build

```bash
git clone https://github.com/jimmyLC/MacFlac.git
cd MacFlac
./build.sh
open build/MacFlac.app
```

`./build-dmg.sh` makes a drag-to-Applications disk image. The build is ad-hoc signed (no notarization).

## CLI

```bash
build/macflac-cli ~/Music/Album            # next to the sources
build/macflac-cli --out ~/Flac --jobs 8 --level 0 a.mp3 b.wav
```

Options: `--out DIR`, `--jobs N` (1–16), `--level 0–8` (0 fastest, 5 default, 8 smallest), `--overwrite`.

## License

Open source, no license. Conversion is done by FFmpeg, which MacFlac neither bundles nor distributes.
