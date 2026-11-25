// Engine.swift — ffmpeg/ffprobe 操作核心(無 UI 依賴,GUI 和 CLI 共用)
import Foundation
import Darwin

struct ProbeResult {
    var audioCodec: String?
    var sampleFormat: String?
    /// 位元深度(來源是有損編碼時為 nil)
    var bitDepth: Int?
    var sampleRate: Int?
    var channels: Int?
    /// 封面圖串流的索引(僅限 FLAC 能直接嵌入的 mjpeg / png)
    var coverIndex: Int?
    var duration: Double?
    var hasAudio: Bool { audioCodec != nil }
    var isValidOutput: Bool {
        guard hasAudio, let duration else { return false }
        return duration.isFinite && duration > 0
    }
}

/// FLAC 壓縮等級。數字越大檔案越小、越慢;所有等級都是無損,解碼出來的音訊完全一樣。
enum FlacSpeed: Int, CaseIterable, Identifiable {
    case fastest = 0, standard = 5, smallest = 8
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fastest: return L("最快")
        case .standard: return L("標準")
        case .smallest: return L("最小檔案")
        }
    }
}

struct Strategy {
    let label: String
    let args: [String]
}

enum FF {

    /// 在常見位置找工具(含 Homebrew 路徑,GUI App 的 PATH 通常不含它們)
    static func findTool(_ name: String) -> String? {
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/opt/local/bin/\(name)",
        ]
        if let envPath = ProcessInfo.processInfo.environment["PATH"], !envPath.isEmpty {
            candidates.append(contentsOf: envPath.split(separator: ":").map { "\($0)/\(name)" })
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    /// 用 ffprobe 讀取第一條音軌、封面與時長
    static func probe(url: URL, ffprobe: String, didStart: ((Process) -> Void)? = nil) -> ProbeResult? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        didStart?(p)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        var result = ProbeResult()
        if let streams = obj["streams"] as? [[String: Any]] {
            for s in streams {
                let type = s["codec_type"] as? String
                let codec = s["codec_name"] as? String
                if type == "audio", result.audioCodec == nil, let codec {
                    result.audioCodec = codec
                    result.sampleFormat = s["sample_fmt"] as? String
                    result.sampleRate = (s["sample_rate"] as? String).flatMap { Int($0) }
                    result.channels = s["channels"] as? Int
                    let raw = (s["bits_per_raw_sample"] as? String).flatMap { Int($0) }
                    let bps = s["bits_per_sample"] as? Int
                    result.bitDepth = raw ?? ((bps ?? 0) > 0 ? bps : nil)
                } else if type == "video", result.coverIndex == nil,
                          (s["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1,
                          let codec, codec == "mjpeg" || codec == "png",
                          let index = s["index"] as? Int {
                    result.coverIndex = index
                }
            }
        }
        if let f = obj["format"] as? [String: Any],
           let d = f["duration"] as? String, let v = Double(d) {
            result.duration = v
        }
        return result
    }

    /// 決定輸出取樣格式:保留 16 / 24 bit 來源的位元深度;有損來源(MP3、AAC…)解成 16 bit。
    static func audioArgs(for probe: ProbeResult, speed: FlacSpeed) -> [String] {
        var args = ["-c:a", "flac", "-compression_level", String(speed.rawValue)]
        let codec = probe.audioCodec ?? ""
        if codec.hasPrefix("dsd") {
            // DSD 是 1-bit 高速取樣,FLAC 放不下:降成 88.2 kHz / 24 bit
            args += ["-ar", "88200", "-sample_fmt", "s32"]
        } else if let depth = probe.bitDepth, depth > 16 {
            args += ["-sample_fmt", "s32"]
        } else if let format = probe.sampleFormat, format.hasPrefix("s32") || format.hasPrefix("flt") || format.hasPrefix("dbl"),
                  isLossless(codec) {
            // 沒標明位元深度的高解析來源(例如浮點 WAV)
            args += ["-sample_fmt", "s32"]
        } else {
            args += ["-sample_fmt", "s16"]
        }
        // FLAC 規格最高 8 聲道
        if let channels = probe.channels, channels > 8 { args += ["-ac", "8"] }
        return args
    }

    static func isLossless(_ codec: String) -> Bool {
        codec.hasPrefix("pcm_") || ["alac", "ape", "wavpack", "tta", "truehd", "mlp", "tak"].contains(codec)
    }

    /// 由快到慢的轉換策略:先帶封面,失敗再不帶封面。
    static func strategies(for probe: ProbeResult, speed: FlacSpeed) -> [Strategy] {
        let audio = audioArgs(for: probe, speed: speed)
        // 只取第一條音軌(FLAC 一個檔案只能有一條),影片畫面一律丟掉
        let base = ["-map", "0:a:0", "-map_metadata", "0"]
        var list: [Strategy] = []
        if let cover = probe.coverIndex {
            list.append(Strategy(label: L("轉換中"), args: base + ["-map", "0:\(cover)", "-c:v", "copy",
                                                                    "-disposition:v:0", "attached_pic"] + audio))
            list.append(Strategy(label: L("不含封面重試"), args: base + audio))
        } else {
            list.append(Strategy(label: L("轉換中"), args: base + audio))
        }
        return list
    }

    /// 執行 ffmpeg 轉換。progress: (百分比(-1=未知), 速度字串)
    static func run(ffmpeg: String, input: URL, output: URL, strategy: Strategy,
                    duration: Double?,
                    didStart: ((Process) -> Void)? = nil,
                    progress: @escaping (Double, String) -> Void,
                    errorOutput: ((String) -> Void)? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)

        var args = ["-hide_banner", "-nostdin", "-y",
                    // 容錯:遇到零星壞封包直接跳過,不中斷整批
                    "-err_detect", "ignore_err", "-fflags", "+discardcorrupt"]
        args += ["-i", input.path]
        args += strategy.args
        args += ["-f", "flac", "-progress", "pipe:1", "-nostats", output.path]
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        var buffer = Data()
        var lastSpeed = ""
        var errorTail = Data()
        let errorTailLimit = 16 * 1024

        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            buffer.append(d)
            while let idx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<idx)
                buffer.removeSubrange(buffer.startIndex...idx)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                    let eq = line.firstIndex(of: "=")!
                    let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if let us = Double(raw) {
                        let pct: Double
                        if let dur = duration, dur > 0 {
                            pct = min(100, max(0, us / 1_000_000 / dur * 100))
                        } else {
                            pct = -1
                        }
                        progress(pct, lastSpeed)
                    }
                } else if line.hasPrefix("speed=") {
                    lastSpeed = String(line.dropFirst("speed=".count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData   // 排空 stderr,避免 ffmpeg 卡住
            if d.isEmpty { fh.readabilityHandler = nil; return }
            errorTail.append(d)
            if errorTail.count > errorTailLimit { errorTail = errorTail.suffix(errorTailLimit) }
        }

        do { try p.run() } catch { return false }
        didStart?(p)
        p.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        errorTail.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        errorOutput?(String(decoding: errorTail.suffix(errorTailLimit), as: UTF8.self))
        return p.terminationStatus == 0
    }

    /// 輸出時長必須接近來源(容許 2% 或 1 秒),避免半截檔被當成功。
    static func outputMatches(_ output: ProbeResult, source: ProbeResult) -> Bool {
        guard output.isValidOutput else { return false }
        guard let want = source.duration, want > 0, let got = output.duration else { return true }
        return abs(got - want) <= max(1.0, want * 0.02)
    }
}

/// 每次轉換先寫到來源旁的私有暫存資料夾,驗證通過才原子改名成最終檔名。
final class OutputTransaction {
    let temporaryURL: URL
    private let directory: URL
    private let destination: URL
    private let overwrite: Bool

    init(destination: URL, overwrite: Bool) throws {
        self.destination = destination
        self.overwrite = overwrite
        try Self.validateDestination(destination, overwrite: overwrite)
        let parent = destination.deletingLastPathComponent()
        Self.removeStaleDirectories(in: parent)
        directory = parent.appendingPathComponent("\(Self.prefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryURL = directory.appendingPathComponent("output.flac")
    }

    /// 暫存資料夾名為 `.macflac-p<pid>-<uuid>`;當機或被強制結束時不會跑 deinit,
    /// 所以下次啟動時會清掉「擁有者程序已不存在」的資料夾。
    private static let prefix = ".macflac-p"
    private static let cleanedLock = NSLock()
    private static var cleanedDirectories = Set<String>()

    static func removeStaleDirectories(in parent: URL) {
        cleanedLock.lock()
        let first = cleanedDirectories.insert(parent.standardizedFileURL.path).inserted
        cleanedLock.unlock()
        guard first, let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard let pidText = rest.split(separator: "-", maxSplits: 1).first, let pid = pid_t(pidText) else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
            }
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    private static func validateDestination(_ url: URL, overwrite: Bool) throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return }
            throw error
        }
        guard overwrite, attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NSError(domain: "MacFlac.Output", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(format: L("輸出位置已存在或不是一般檔案: %@"), url.lastPathComponent)])
        }
    }

    func commit() throws {
        try Self.validateDestination(destination, overwrite: overwrite)
        var failure: Int32 = 0
        temporaryURL.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                if overwrite {
                    if Darwin.rename(source!, target!) != 0 { failure = errno }
                } else if Darwin.renamex_np(source!, target!, UInt32(RENAME_EXCL)) != 0 {
                    failure = errno
                    // exFAT 與部分網路磁碟沒有 RENAME_EXCL:先檢查再一般改名
                    if failure == ENOTSUP || failure == EINVAL {
                        var info = stat()
                        if Darwin.lstat(target!, &info) == 0 { failure = EEXIST }
                        else { failure = Darwin.rename(source!, target!) == 0 ? 0 : errno }
                    }
                }
            }
        }
        guard failure == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure)) }
    }

    func discardAttempt() { try? FileManager.default.removeItem(at: temporaryURL) }

    deinit { cleanup() }
}

/// 避免同一批裡 `a.mp3` 與 `a.wav` 都輸出成 `a.flac` 而互相覆蓋。
func uniqueOutputURL(_ url: URL, claimed: Set<String>) -> URL {
    guard claimed.contains(url.standardizedFileURL.path) else { return url }
    let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
    var n = 2
    while true {
        let candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
        if !claimed.contains(candidate.standardizedFileURL.path) { return candidate }
        n += 1
    }
}

/// 秒數 → "H:MM:SS" / "M:SS"
func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%d:%02d", m, sec)
}

/// 耗時 → 未滿 60 秒顯示 "12.4 秒",超過顯示 "M:SS"
func formatElapsed(_ seconds: Double) -> String {
    if seconds < 60 { return String(format: L("%.1f 秒"), seconds) }
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// 掃描資料夾時採用的副檔名(單獨拖進來的檔案不受限,交給 ffprobe 判斷)。FLAC 本身不列入。
let supportedExtensions: Set<String> = [
    // 音訊
    "mp3", "m4a", "m4b", "m4r", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "wma", "ogg", "oga",
    "opus", "ape", "wv", "tta", "tak", "dsf", "dff", "alac", "amr", "au", "snd", "mka", "mp2", "mpa",
    "ac3", "eac3", "dts", "mpc", "ra", "weba", "3ga", "spx", "gsm", "w64", "rf64", "voc",
    // 影片(取出音軌)
    "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "asf", "ts", "m2ts", "mts", "mpg", "mpeg",
    "3gp", "3g2", "ogv", "vob", "rm", "rmvb",
]

/// 取用本地化字串:程式碼以「繁體中文原文」作為 key,
/// 英文翻譯位於 Resources/en.lproj/Localizable.strings。
/// 可用 UserDefaults 的 "AppLanguage"("zh-Hant" / "en")覆寫系統語言。
func L(_ key: String) -> String {
    var bundle = Bundle.main
    if let code = UserDefaults.standard.string(forKey: "AppLanguage"),
       let path = Bundle.main.path(forResource: code, ofType: "lproj"),
       let b = Bundle(path: path) {
        bundle = b
    }
    return bundle.localizedString(forKey: key, value: key, table: nil)
}
