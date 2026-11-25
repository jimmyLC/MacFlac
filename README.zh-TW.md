# MacFlac

**macOS 上的批次音樂轉 FLAC 工具,快。**

把任何音樂檔(`mp3` / `m4a` / `wav` / `aiff` / `ape` / `wma` / `opus` / `ogg` / `dsf` …,甚至影片)拖進來就轉成 `.flac`。多檔同時轉換,整張專輯幾秒就好。

[English →](README.md)

## 特色

- 🚀 **快** — 多檔並行(預設每個效能核心一個,最多 8)。M 系列 Mac 上 40 分鐘的音樂約 1 秒轉完。
- 🎵 **幾乎什麼都能轉** — MP3、AAC/M4A、WAV、AIFF、ALAC、APE、WavPack、WMA、Opus、Ogg、DSD、AC3/DTS,以及影片(mkv / mp4 / mov / ts …)的音軌。
- 🎚 **依位元深度輸出** — 16-bit 維持 16-bit,24-bit／浮點來源輸出 24-bit,有損來源解成 16-bit。
- 🏷 **保留標籤與封面** — 曲名、歌手、專輯與內嵌 JPEG/PNG 封面都會帶過去。
- 🛟 **安全** — 先寫到私有暫存資料夾,驗證長度與音軌後才改名到位;原始檔絕不動。
- 🗂 **批次佇列** — 拖入檔案或整個資料夾,逐檔進度、Finder 顯示、失敗重試。
- 🌐 繁體中文／English,原生 SwiftUI(macOS 26 使用 Liquid Glass)。
- ⌨️ 附命令列版。

> FLAC 是無損格式,但無法找回 MP3、AAC 等有損來源已經丟掉的細節:轉出來檔案會變大,聽起來一樣。

壓縮等級(最快／標準／最小檔案)只影響速度與檔案大小,音質完全相同。

## 需求

- Apple Silicon Mac、macOS 13 以上
- [ffmpeg](https://ffmpeg.org) — `brew install ffmpeg`(第一次開啟時 App 可以代為安裝)

## 建置

```bash
git clone https://github.com/jimmyLC/MacFlac.git
cd MacFlac
./build.sh
open build/MacFlac.app
```

`./build-dmg.sh` 會產生拖曳安裝的 DMG。建置為 ad-hoc 簽名(未公證)。

## 命令列

```bash
build/macflac-cli ~/Music/Album
build/macflac-cli --out ~/Flac --jobs 8 --level 0 a.mp3 b.wav
```

## 授權

開源,不附授權條款。轉檔由 FFmpeg 完成,MacFlac 不包含也不散布 FFmpeg。
