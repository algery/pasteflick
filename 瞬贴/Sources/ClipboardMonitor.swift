import AppKit
import os

enum HistoryLog {
    static let storage = Logger(subsystem: "local.shuntie", category: "Storage")
    static let capture = Logger(subsystem: "local.shuntie", category: "Clipboard")
}

enum HistoryIssue: Equatable {
    case pasteFailure(String)
    case starting, historyUnavailable, clipboardUnavailable, permissionRequired, tooLarge, saveFailed, saveUnconfirmed

    var title: String {
        switch self {
        case .pasteFailure: "这条历史未能复制"
        case .starting: "正在读取历史"
        case .historyUnavailable: "暂时无法读取历史"
        case .clipboardUnavailable: "刚才的内容无法读取"
        case .permissionRequired: "暂时无法记录新的复制"
        case .tooLarge: "刚才的内容超过保存上限"
        case .saveFailed: "刚才的内容未能保存"
        case .saveUnconfirmed: "暂时无法确认刚才的内容已保存"
        }
    }

    var detail: String {
        switch self {
        case .pasteFailure(let message): message
        case .starting: ""
        case .historyUnavailable: "已有历史仍保留。请重试。"
        case .clipboardUnavailable: "已有历史仍保留。请重新复制。"
        case .permissionRequired: "请在系统设置中允许瞬贴读取剪贴板。已有历史仍可使用。"
        case .tooLarge: "单条及历史总容量最多 1 GB。已有历史仍保留。"
        case .saveFailed: "已有历史仍保留。请检查本机存储空间后重新复制。"
        case .saveUnconfirmed: "刚才的内容已显示，退出重开后可能需要重新复制。"
        }
    }

    var isPermission: Bool { self == .permissionRequired }
}

private actor HistoryWorker {
    let directory: URL
    let limits: HistoryLimits
    private var store: HistoryStore?

    init(directory: URL, limits: HistoryLimits) {
        self.directory = directory
        self.limits = limits
    }

    func load() throws -> HistoryContents {
        if let store { return store.contents }
        let opened = try HistoryStore(directory: directory, limits: limits)
        store = opened
        return opened.contents
    }

    func representations(for id: UUID) throws -> [[ClipboardSnapshot.Representation]] {
        guard let store else { throw HistoryStoreError.invalidIndex }
        return try store.representations(for: id)
    }

    func record(_ snapshot: ClipboardSnapshot, copiedAt: Date) throws -> HistoryContents {
        guard let store else { throw HistoryStoreError.invalidIndex }
        return try store.save(snapshot, copiedAt: copiedAt)
    }
}

@MainActor
final class ClipboardMonitor {
    static let pollInterval: TimeInterval = 0.25

    private let source: ClipboardSource
    private let worker: HistoryWorker
    private let limits: HistoryLimits
    private var timer: Timer?
    private var version: Int
    private var ownWrite: Int?
    private var access: ClipboardAccess
    private var triedWhileAsking = false
    private var loaded = false
    private var working = false
    private var onIdle: (() -> Void)?
    private(set) var contents = HistoryContents()
    private(set) var storageIssue: HistoryIssue? = .starting
    private(set) var captureIssue: HistoryIssue?
    var onChange: (() -> Void)?

    var issue: HistoryIssue? { storageIssue ?? captureIssue }

    init(source: ClipboardSource, directory: URL, limits: HistoryLimits = .standard) {
        self.source = source
        self.limits = limits
        worker = HistoryWorker(directory: directory, limits: limits)
        version = source.version()
        access = source.access()
    }

    func ignoreOwnWrite(_ version: Int) { ownWrite = version }

    func representations(for id: UUID) async throws -> [[ClipboardSnapshot.Representation]] {
        try await worker.representations(for: id)
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, target: self, selector: #selector(tick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { if self.timer != nil { await refreshHistory() } }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func finish() async {
        stop()
        if working {
            await withCheckedContinuation { continuation in
                onIdle = { continuation.resume() }
            }
        }
        if storageIssue == .starting { await refreshHistory() }
        await poll()
    }

    func refreshHistory() async {
        guard !working, !loaded else { return }
        working = true
        defer { finishedWork() }
        do {
            contents = try await worker.load()
            loaded = true
            storageIssue = nil
        } catch {
            storageIssue = .historyUnavailable
            HistoryLog.storage.error("History load failed: \((error as NSError).code)")
        }
        onChange?()
    }

    @objc private func tick() {
        guard !working else { return }
        Task { if self.timer != nil { await poll() } }
    }

    func poll() async {
        guard !working else { return }
        working = true
        defer { finishedWork() }
        let currentAccess = source.access()
        let currentVersion = source.version()
        if currentAccess != access {
            if currentAccess == .available { triedWhileAsking = false }
            access = currentAccess
        }

        let blocked = currentAccess == .denied ||
            (currentAccess == .ask && triedWhileAsking && (version != currentVersion || captureIssue == .permissionRequired))
        if blocked {
            if captureIssue != .permissionRequired { updateCaptureIssue(.permissionRequired) }
            return
        }
        if captureIssue == .permissionRequired { updateCaptureIssue(nil) }
        guard loaded, version != currentVersion else { return }
        version = currentVersion
        let isOwnWrite = ownWrite == currentVersion
        ownWrite = nil
        if isOwnWrite { return }

        let result = ClipboardCapture.read(source, version: currentVersion, byteLimit: limits.bytes)
        if source.access() == .ask { triedWhileAsking = true }
        switch result {
        case .ignored, .superseded: break
        case .denied:
            updateCaptureIssue(.permissionRequired)
        case .readFailed:
            if source.access() == .ask {
                updateCaptureIssue(.permissionRequired)
            } else {
                HistoryLog.capture.error("Clipboard representation could not be read")
                updateCaptureIssue(.clipboardUnavailable)
            }
        case .tooLarge: updateCaptureIssue(.tooLarge)
        case .snapshot(let snapshot):
            do {
                contents = try await worker.record(snapshot, copiedAt: .now)
                updateCaptureIssue(contents.durabilityPending ? .saveUnconfirmed : nil)
            } catch HistoryStoreError.tooLarge {
                updateCaptureIssue(.tooLarge)
            } catch {
                HistoryLog.storage.error("History save failed: \((error as NSError).code)")
                updateCaptureIssue(.saveFailed)
            }
        }
    }

    private func finishedWork() {
        working = false
        let completion = onIdle
        onIdle = nil
        completion?()
    }

    private func updateCaptureIssue(_ issue: HistoryIssue?) {
        captureIssue = issue
        onChange?()
    }
}
