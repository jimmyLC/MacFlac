// main.swift — 命令列版(與 GUI 同一顆引擎,同樣多檔並行)
import Foundation

func printUsage() {
    print("""
    MacFlac CLI — 任何音樂檔轉 FLAC(無損、多檔並行)

    用法:
      macflac-cli [選項] 檔案或資料夾...

    選項:
      --out <目錄>      指定輸出資料夾(預設:與來源同資料夾)
      --jobs <N>        同時轉換的檔數(預設:效能核心數,最多 8)
      --level <0-8>     FLAC 壓縮等級:0 最快、5 標準、8 最小檔案(預設 5)
      --overwrite       輸出檔已存在時覆蓋(預設略過)
      -h, --help        顯示說明
    """)
    print("Copyright © 2026 JimmyLC · https://jimmy-tools.com/")
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var inputs: [URL] = []
var outDir: URL?
var overwrite = false
var level = 5
var jobs = 0

let args = CommandLine.arguments
var i = 1
func value(_ name: String) -> String {
    i += 1
    guard i < args.count else { fail("\(name) 需要指定值。") }
    return args[i]
}
while i < args.count {
    switch args[i] {
    case "--out": outDir = URL(fileURLWithPath: value("--out"))
    case "--jobs":
        guard let n = Int(value("--jobs")), n >= 1, n <= 16 else { fail("--jobs 需要 1 到 16。") }
        jobs = n
    case "--level":
        guard let n = Int(value("--level")), (0...8).contains(n) else { fail("--level 需要 0 到 8。") }
        level = n
    case "--overwrite": overwrite = true
    case "-h", "--help": printUsage(); exit(0)
    default: inputs.append(URL(fileURLWithPath: args[i]))
    }
    i += 1
}
if inputs.isEmpty { printUsage(); exit(2) }

guard let ffmpeg = FF.findTool("ffmpeg"), let ffprobe = FF.findTool("ffprobe") else {
    fail("找不到 ffmpeg。請先執行:brew install ffmpeg", code: 3)
}
if jobs == 0 {
    var count: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) != 0 || count <= 0 {
        count = Int32(ProcessInfo.processInfo.activeProcessorCount)
    }
    jobs = max(2, min(8, Int(count)))
}
let speed = FlacSpeed(rawValue: level) ?? .standard
let speedLevel = level

// 收集檔案
var files: [URL] = []
for url in inputs {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        FileHandle.standardError.write(Data("找不到: \(url.path)\n".utf8)); continue
    }
    if isDir.boolValue {
        var found: [URL] = []
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let f as URL in en where supportedExtensions.contains(f.pathExtension.lowercased()) { found.append(f) }
        }
        files += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    } else {
        files.append(url)
    }
}

let lock = NSLock()
var claimed = Set<String>()
var okCount = 0, failCount = 0, skipCount = 0
func log(_ s: String) { lock.lock(); print(s); fflush(stdout); lock.unlock() }

func convert(_ file: URL) {
    let name = file.lastPathComponent
    if file.pathExtension.lowercased() == "flac" { lock.lock(); skipCount += 1; lock.unlock(); log("略過(已是 FLAC): \(name)"); return }
    let dir = outDir ?? file.deletingLastPathComponent()
    lock.lock()
    let dest = uniqueOutputURL(dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".flac"), claimed: claimed)
    claimed.insert(dest.standardizedFileURL.path)
    lock.unlock()
    if FileManager.default.fileExists(atPath: dest.path) && !overwrite {
        lock.lock(); skipCount += 1; lock.unlock(); log("略過(輸出已存在): \(dest.lastPathComponent)"); return
    }
    func failed(_ why: String) { lock.lock(); failCount += 1; lock.unlock(); log("失敗: \(name) — \(why)") }
    guard let probe = FF.probe(url: file, ffprobe: ffprobe) else { failed("無法讀取檔案"); return }
    guard probe.hasAudio else { failed("找不到音訊串流"); return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let transaction: OutputTransaction
    do { transaction = try OutputTransaction(destination: dest, overwrite: overwrite) }
    catch { failed(error.localizedDescription); return }
    let start = Date()
    for strategy in FF.strategies(for: probe, speed: FlacSpeed(rawValue: speedLevel) ?? speed) {
        let ok = FF.run(ffmpeg: ffmpeg, input: file, output: transaction.temporaryURL, strategy: strategy,
                        duration: probe.duration, progress: { _, _ in })
        if ok, let out = FF.probe(url: transaction.temporaryURL, ffprobe: ffprobe), FF.outputMatches(out, source: probe) {
            do { try transaction.commit() } catch { failed(error.localizedDescription); return }
            lock.lock(); okCount += 1; lock.unlock()
            log("完成: \(dest.lastPathComponent) (\(formatElapsed(Date().timeIntervalSince(start))))")
            return
        }
        transaction.discardAttempt()
    }
    failed("轉換失敗(來源檔可能損壞)")
}

let queue = DispatchQueue(label: "macflac.cli", attributes: .concurrent)
let slots = DispatchSemaphore(value: jobs)
let group = DispatchGroup()
let began = Date()
for file in files {
    slots.wait()
    queue.async(group: group) { convert(file); slots.signal() }
}
group.wait()
print("共 \(files.count) 個:完成 \(okCount)、略過 \(skipCount)、失敗 \(failCount) — 耗時 \(formatElapsed(Date().timeIntervalSince(began)))")
exit(failCount > 0 ? 1 : 0)
