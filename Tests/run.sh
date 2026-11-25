#!/bin/zsh
# MacFlac 回歸測試:授權/外觀(Swift)、收款後端(Node)、轉檔 CLI(合成音檔)。用法: Tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d "${TMPDIR:-/private/tmp}/macflac-tests.XXXXXX"); trap 'rm -rf "$T"' EXIT
export CLANG_MODULE_CACHE_PATH=/private/tmp/macflac-module-cache SWIFT_MODULECACHE_PATH=/private/tmp/macflac-module-cache

echo "== 外觀權限"
swiftc -swift-version 5 -parse-as-library Sources/Engine.swift Sources/AppAccess.swift Tests/AppearanceRegression.swift -o "$T/appearance" && "$T/appearance"
echo "== 授權(簽章、鑰匙圈、裝置綁定)"
node payments/scripts/license-fixtures.mjs "$T/fixture.json"
swiftc -swift-version 5 -parse-as-library Sources/Engine.swift Sources/AppAccess.swift Sources/ProLicense.swift Tests/ProLicenseRegression.swift -o "$T/license" && "$T/license" "$T/fixture.json"
echo "== 收款後端"
(cd payments && npm test --silent 2>&1 | tail -8)
echo "== 轉檔 CLI"
swiftc -O -swift-version 5 Sources/Engine.swift CLI/main.swift -o "$T/cli" 2>/dev/null
mkdir "$T/in"
ffmpeg -loglevel error -f lavfi -i "sine=f=440:d=2" -c:a libmp3lame "$T/in/lossy.mp3"
ffmpeg -loglevel error -f lavfi -i "sine=f=330:d=2:sample_rate=96000" -c:a pcm_s24le "$T/in/hires.wav"
ffmpeg -loglevel error -f lavfi -i "sine=f=220:d=2" -c:a pcm_s16le "$T/in/cd.wav"
"$T/cli" --jobs 3 "$T/in"
probe() { ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,bits_per_raw_sample -of csv=p=0 "$1"; }
[[ $(probe "$T/in/lossy.flac") == flac,16 ]] || { echo "FAIL lossy depth: $(probe $T/in/lossy.flac)"; exit 1; }
[[ $(probe "$T/in/hires.flac") == flac,24 ]] || { echo "FAIL hires depth: $(probe $T/in/hires.flac)"; exit 1; }
for n in cd hires; do
  fmt=pcm_s16le; [[ $n == hires ]] && fmt=pcm_s24le
  [[ $(ffmpeg -loglevel error -i "$T/in/$n.wav" -c:a $fmt -f md5 -) == $(ffmpeg -loglevel error -i "$T/in/$n.flac" -c:a $fmt -f md5 -) ]] || { echo "FAIL not bit-exact: $n"; exit 1; }
done
again=$("$T/cli" "$T/in"); [[ $again == *"略過(輸出已存在)"* ]] || { echo "FAIL rerun should skip"; exit 1; }
echo "ALL PASS"
