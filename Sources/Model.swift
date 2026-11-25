// Model.swift — 佇列與並行批次轉換邏輯
import Foundation
import Combine
import AppKit

enum JobStatus: Equatable {
    case waiting
    case probing
    case converting(percent: Double, speed: String, label: String)
    case done(elapsed: Double, outSize: Int64)
    case failed(String)
    case skipped(String)
}

final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    @Published var status: JobStatus = .waiting
    @Published var duration: Double?
    @Published var outURL: URL?

    init(url: URL) {
        self.url = url
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// 預設同時轉換的檔數:用效能核心數,最多 8。FLAC 編碼是單執行緒,多檔並行才吃得滿 CPU。
func defaultConcurrency() -> Int {
    var count: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) != 0 || count <= 0 {
        count = Int32(ProcessInfo.processInfo.activeProcessorCount)
    }
    return max(2, min(8, Int(count)))
}

final class JobStore: ObservableObject {
    static let shared = JobStore()

    @Published private(set) var ffmpeg: String?
    @Published private(set) var ffprobe: String?

    @Published var jobs: [Job] = []
    @Published var isRunning = false
    @Published var outputToSource = true
    @Published var customOutputDir: URL?
    @Published var overwrite = false
    @Published var autoStart = false
    @Published var speed: FlacSpeed = .standard
    @Published var concurrency = defaultConcurrency()
    @Published var flashMessage: String?
    @Published var appLanguage: String = UserDefaults.standard.string(forKey: "AppLanguage") ?? "system" {
        didSet {
            guard oldValue != appLanguage else { return }
            if appLanguage == "system" {
                UserDefaults.standard.removeObject(forKey: "AppLanguage")
            } else {
                UserDefaults.standard.set(appLanguage, forKey: "AppLanguage")
            }
            flash(L("語言已切換,重新開啟 App 後全部生效"))
        }
    }

    /// 開始一批時複製一次設定,批次中調整介面不會影響已排入的檔案。
    private struct RunOptions {
        var outputToSource = true
        var customOutputDir: URL?
        var overwrite = false
        var speed: FlacSpeed = .standard
    }
    private var runOptions = RunOptions()
    private let optionsLock = NSLock()
    private var activeOptions: RunOptions {
        get { optionsLock.lock(); defer { optionsLock.unlock() }; return runOptions }
        set { optionsLock.lock(); defer { optionsLock.unlock() }; runOptions = newValue }
    }
    /// 本批已被占用的輸出路徑(受 lock 保護)
    private var claimedOutputs: [UUID: String] = [:]

    private var jobObservers: [UUID: AnyCancellable] = [:]
    private var pending: [Job] = []
    private var pendingIDs = Set<UUID>()
    private let lock = NSLock()
    private let stopLock = NSLock()
    private var stopped = false
    private var stopRequested: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return stopped }
        set { stopLock.lock(); defer { stopLock.unlock() }; stopped = newValue }
    }
    private var runningProcesses: [ObjectIdentifier: Process] = [:]
    private let procLock = NSLock()

    init(ffmpeg: String? = FF.findTool("ffmpeg"), ffprobe: String? = FF.findTool("ffprobe")) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    func refreshTools(find: (String) -> String? = FF.findTool) {
        guard !isRunning else { return }
        ffmpeg = find("ffmpeg")
        ffprobe = find("ffprobe")
    }

    // MARK: - 對外操作(全部在主執行緒呼叫)

    var hasWaiting: Bool { jobs.contains { $0.status == .waiting } }
    var waitingCount: Int { jobs.filter { $0.status == .waiting }.count }
    var doneCount: Int { jobs.filter { if case .done = $0.status { return true }; return false }.count }
    var failedCount: Int { jobs.filter { if case .failed = $0.status { return true }; return false }.count }
    var finishedCount: Int {
        jobs.filter { switch $0.status { case .done, .skipped: return true; default: return false } }.count
    }
    var processedCount: Int { finishedCount + failedCount }
    var totalBytes: Int64 { jobs.reduce(0) { $0 + $1.size } }

    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        var total = 0.0
        for j in jobs {
            switch j.status {
            case .done, .failed, .skipped: total += 1
            case .converting(let p, _, _): total += max(0, p) / 100
            default: break
            }
        }
        return total / Double(jobs.count)
    }

    func add(urls: [URL]) {
        var existing = Set(jobs.map { $0.url.standardizedFileURL.path })
        var newJobs: [Job] = []
        var capped = false

        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let en = FileManager.default.enumerator(
                    at: u, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    var count = 0
                    for case let f as URL in en {
                        if count >= 5000 { capped = true; break }
                        guard supportedExtensions.contains(f.pathExtension.lowercased()) else { continue }
                        let key = f.standardizedFileURL.path
                        if existing.contains(key) { continue }
                        existing.insert(key)
                        newJobs.append(Job(url: f))
                        count += 1
                    }
                }
            } else {
                // 單獨拖進來的檔案不看副檔名,不是音訊的交給 ffprobe 回報
                let key = u.standardizedFileURL.path
                if !existing.contains(key) {
                    existing.insert(key)
                    newJobs.append(Job(url: u))
                }
            }
        }

        newJobs.sort {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        for job in newJobs {
            jobObservers[job.id] = job.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        if !newJobs.isEmpty { jobs.append(contentsOf: newJobs) }
        if capped { flash(L("資料夾內音樂超過 5000 首，只加入前 5000 首")) }
        if autoStart { start() }
    }

    func start() {
        guard ffmpeg != nil, ffprobe != nil else { return }
        if !isRunning {
            activeOptions = RunOptions(outputToSource: outputToSource, customOutputDir: customOutputDir,
                                       overwrite: overwrite, speed: speed)
        }
        enqueueNew()
        guard !isRunning, hasPending() else { return }
        isRunning = true
        stopRequested = false
        let workers = max(1, min(16, concurrency))
        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { group.leave() }
                guard let self else { return }
                while !self.stopRequested, let job = self.nextPending() {
                    self.process(job)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.claimedOutputs.removeAll(); self.lock.unlock()
            self.isRunning = false
            // 轉換途中又加入的新檔案:接著跑
            if !self.stopRequested, self.hasPending() { self.start() }
        }
    }

    func stop() {
        stopRequested = true
        procLock.lock()
        let all = Array(runningProcesses.values)
        procLock.unlock()
        for p in all where p.isRunning { p.terminate() }
    }

    func remove(_ job: Job) {
        switch job.status { case .probing, .converting: return; default: break }
        jobObservers.removeValue(forKey: job.id)
        jobs.removeAll { $0.id == job.id }
        lock.lock()
        pending.removeAll { $0.id == job.id }
        pendingIDs.remove(job.id)
        lock.unlock()
    }

    func retry(_ job: Job) {
        if case .failed = job.status {
            job.status = .waiting
            start()
        }
    }

    func clearFinished() {
        jobs.removeAll { j in
            switch j.status {
            case .done, .skipped:
                jobObservers.removeValue(forKey: j.id)
                return true
            default: return false
            }
        }
    }

    // MARK: - 內部

    private func flash(_ s: String) {
        flashMessage = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.flashMessage == s { self?.flashMessage = nil }
        }
    }

    private func enqueueNew() {
        lock.lock()
        defer { lock.unlock() }
        for j in jobs where j.status == .waiting && !pendingIDs.contains(j.id) {
            pending.append(j)
            pendingIDs.insert(j.id)
        }
    }

    private func hasPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    private func nextPending() -> Job? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let j = pending.removeFirst()
        pendingIDs.remove(j.id)
        return j
    }

    private func setStatus(_ job: Job, _ s: JobStatus) {
        DispatchQueue.main.async { job.status = s }
    }

    private func track(_ process: Process) {
        procLock.lock()
        runningProcesses[ObjectIdentifier(process)] = process
        procLock.unlock()
        // 涵蓋「停止」剛好發生在檢查與啟動之間
        if stopRequested, process.isRunning { process.terminate() }
    }

    private func untrack(_ process: Process) {
        procLock.lock()
        runningProcesses.removeValue(forKey: ObjectIdentifier(process))
        procLock.unlock()
    }

    private func probe(_ url: URL, using ffprobe: String) -> ProbeResult? {
        var started: Process?
        defer { if let started { untrack(started) } }
        return FF.probe(url: url, ffprobe: ffprobe, didStart: { [weak self] p in started = p; self?.track(p) })
    }

    private func claimOutput(for job: Job, wanted: URL) -> URL {
        lock.lock()
        defer { lock.unlock() }
        let others = Set(claimedOutputs.filter { $0.key != job.id }.values)
        let url = uniqueOutputURL(wanted, claimed: others)
        claimedOutputs[job.id] = url.standardizedFileURL.path
        return url
    }

    private func process(_ job: Job) {
        guard let ffmpeg, let ffprobe else { return }
        let ext = job.url.pathExtension.lowercased()
        let options = activeOptions
        let overwrite = options.overwrite

        if ext == "flac" {
            setStatus(job, .skipped(L("已是 FLAC 格式")))
            return
        }

        let outDir: URL
        if options.outputToSource || options.customOutputDir == nil {
            outDir = job.url.deletingLastPathComponent()
        } else {
            outDir = options.customOutputDir!
        }
        let wanted = outDir.appendingPathComponent(job.url.deletingPathExtension().lastPathComponent + ".flac")
        let outURL = claimOutput(for: job, wanted: wanted)

        if FileManager.default.fileExists(atPath: outURL.path) && !overwrite {
            setStatus(job, .skipped(L("輸出檔已存在")))
            return
        }

        let startTime = Date()
        setStatus(job, .probing)
        guard let probe = self.probe(job.url, using: ffprobe) else {
            setStatus(job, stopRequested ? .waiting : .failed(L("無法讀取檔案")))
            return
        }
        DispatchQueue.main.async { job.duration = probe.duration }
        guard probe.hasAudio else {
            setStatus(job, .failed(L("找不到音訊串流")))
            return
        }

        let transaction: OutputTransaction
        do { transaction = try OutputTransaction(destination: outURL, overwrite: overwrite) }
        catch {
            setStatus(job, .failed(error.localizedDescription))
            return
        }

        for strategy in FF.strategies(for: probe, speed: options.speed) {
            if stopRequested { setStatus(job, .waiting); return }
            setStatus(job, .converting(percent: probe.duration == nil ? -1 : 0, speed: "", label: strategy.label))

            var started: Process?
            let ok = FF.run(ffmpeg: ffmpeg, input: job.url, output: transaction.temporaryURL, strategy: strategy,
                            duration: probe.duration,
                            didStart: { [weak self] p in started = p; self?.track(p) },
                            progress: { [weak self] pct, speed in
                                self?.setStatus(job, .converting(percent: pct, speed: speed, label: strategy.label))
                            })
            if let started { untrack(started) }

            if stopRequested { setStatus(job, .waiting); return }
            if ok, let outProbe = self.probe(transaction.temporaryURL, using: ffprobe), FF.outputMatches(outProbe, source: probe) {
                if stopRequested { setStatus(job, .waiting); return }
                do { try transaction.commit() }
                catch {
                    setStatus(job, .failed(String(format: L("無法儲存輸出: %@"), error.localizedDescription)))
                    return
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                DispatchQueue.main.async { job.outURL = outURL }
                setStatus(job, .done(elapsed: Date().timeIntervalSince(startTime), outSize: size))
                return
            }
            transaction.discardAttempt()
        }
        setStatus(job, .failed(L("轉換失敗(來源檔可能損壞)")))
    }
}
