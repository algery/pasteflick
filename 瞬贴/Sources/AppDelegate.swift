import AppKit
import os
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var historyPanel: HistoryPanel?
    private var settingsWindow: SettingsWindow?
    private var environment: AppEnvironment?
    private var monitor: ClipboardMonitor?
    private var board: NSPasteboard?
    private var quitting = false
    private var shortcutAvailable = false
    private var shortcut: GlobalShortcut?
    private var chord = ShortcutChord.defaultChord
    private var loginError: String?
    private var usesLiveSettings: Bool { environment?.ownsPasteboard == false }
    private var shortcutFile: URL? { environment?.dataDirectory.appending(path: "Shortcut.json") }
    private static let loginInitializedKey = "loginItemInitialized"
    private var target: PasteTarget?
    private var searchTask: Task<Void, Never>?
    private var searchWork: Task<Set<UUID>, Never>?
    private var pasteTask: Task<Void, Never>?
    private var closingToPaste = false
    private var showingPermission = false
    private let pasteFeedback = PasteFeedback()
    private static let permissionGuideKey = "hasShownPastePermissionGuide"

    private var entries: [HistoryEntry] {
        let now = Date.now
        return monitor?.contents.records.map { $0.entry(now: now) } ?? environment?.entries ?? []
    }
    private lazy var countItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openHistory() }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            environment = try AppEnvironment.live(arguments: ProcessInfo.processInfo.arguments)
        } catch {
            Logger(subsystem: "local.shuntie", category: "Startup").error("App environment failed: \((error as NSError).code)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "无法启动瞬贴"
            alert.informativeText = "请重新构建并打开应用。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["SHUNTIE_TEST_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: value == "dark" ? .darkAqua : .aqua)
        }
        #endif

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(countItem)
        menu.addItem(menuItem("打开剪贴板", action: #selector(openHistory)))
        menu.addItem(menuItem("设置…", action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出瞬贴", action: #selector(quit), key: "q"))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = menu
        item.button?.image = Self.menuImage()
        item.button?.toolTip = "瞬贴"
        item.button?.setAccessibilityLabel("瞬贴")
        statusItem = item

        if usesLiveSettings, let shortcutFile, let data = try? Data(contentsOf: shortcutFile),
           let stored = try? JSONDecoder().decode(ShortcutChord.self, from: data),
           stored.isValid && !stored.isReserved {
            chord = stored
        }
        let shortcut = makeShortcut(chord)
        let registration = shortcut.register()
        shortcutAvailable = registration == 0
        if !shortcutAvailable {
            HistoryLog.capture.error("Global shortcut registration failed: \(registration)")
        }
        self.shortcut = shortcut
        refreshPresentation()
        if usesLiveSettings, SMAppService.mainApp.status != .notFound,
           !UserDefaults.standard.bool(forKey: Self.loginInitializedKey) {
            UserDefaults.standard.set(true, forKey: Self.loginInitializedKey)
            if SMAppService.mainApp.status == .notRegistered { changeLogin(enabled: true) }
        }

        if let environment, !environment.showsSamples {
            let clipboard = environment.makePasteboard()
            board = clipboard
            let monitor = ClipboardMonitor(source: ClipboardSource(board: clipboard), directory: environment.dataDirectory)
            self.monitor = monitor
            monitor.onChange = { [weak self] in self?.refreshPresentation() }
            monitor.start()
        }

    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let monitor else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        quitting = true
        pasteTask?.cancel()
        Task {
            await monitor.finish()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcut?.unregister()
        monitor?.stop()
        if environment?.ownsPasteboard == true { board?.releaseGlobally() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuStatus()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if !closingToPaste { historyPanel?.close() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.updatePastePermission(PasteTarget.hasPermission)
            refreshLogin()
        }
    }

    private func updateMenuStatus() {
        if !shortcutAvailable {
            countItem.title = "唤起快捷键暂不可用"
        } else if environment?.showsSamples == true {
            countItem.title = "虚构样例 · \(environment?.entries.count ?? 0) 条"
        } else {
            countItem.title = monitor?.issue?.title ?? "本机保存 · \(monitor?.contents.records.count ?? 0) 条"
        }
    }

    private func refreshPresentation() {
        updateMenuStatus()
        let issue = monitor?.issue
        statusItem?.button?.image = Self.menuImage(hasIssue: !shortcutAvailable || (issue != nil && issue != .starting))
        statusItem?.button?.toolTip = issue.map { "瞬贴 · \($0.title)" } ??
            (shortcutAvailable ? "瞬贴" : "瞬贴 · 唤起快捷键暂不可用")
        if let historyPanel, historyPanel.isVisible {
            historyPanel.refresh(entries: entries, issue: issue)
        }
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.updateHistory(monitor?.contents, issue: issue, samples: environment?.showsSamples == true)
        }
    }

    @objc private func retryHistory() {
        Task { await monitor?.refreshHistory() }
    }

    private func toggleHistory() {
        if let historyPanel, historyPanel.isVisible { historyPanel.close() }
        else { openHistory() }
    }

    @objc private func openHistory() {
        guard let environment, !quitting, !showingPermission else { return }
        if historyPanel?.isVisible != true {
            pasteTask?.cancel()
            pasteFeedback.clear()
            target = PasteTarget.capture()
            if target == nil { HistoryLog.capture.info("No external frontmost application at history opening") }
        }
        Measurements.interval("Open History") {
            let panel = historyPanel ?? HistoryPanel(thumbnails: HistoryThumbnailLoader(directory: environment.dataDirectory))
            historyPanel = panel
            panel.onRetry = { [weak self] in self?.retryHistory() }
            panel.onSettings = { [weak self] in self?.openSettings() }
            panel.onSearch = { [weak self] query in self?.searchHistory(query) }
            panel.onPaste = { [weak self] id in self?.pasteHistory(id) }
            panel.loadPreview = { [weak self] id in
                guard let monitor = self?.monitor else { throw HistoryPayload.Failure.missingRepresentation }
                return try await monitor.representations(for: id)
            }
            panel.onClose = { [weak self] in self?.historyDidClose() }
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            NSApp.activate()
            panel.show(entries: entries, samples: environment.showsSamples, on: screen ?? NSScreen.main,
                       issue: monitor?.issue, shortcut: shortcutAvailable ? chord.label : "")
            panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func historyDidClose() {
        searchTask?.cancel()
        searchWork?.cancel()
        if !closingToPaste {
            pasteTask?.cancel()
            target?.restoreApplication()
        }
        target = nil
    }

    private func searchHistory(_ query: String) {
        searchTask?.cancel()
        searchWork?.cancel()
        guard !query.isEmpty, let environment, let monitor else { return }
        let records = monitor.contents.records
        let directory = environment.dataDirectory
        let previous = searchWork
        let work = Task.detached(priority: .userInitiated) {
            _ = await previous?.value
            guard !Task.isCancelled else { return Set<UUID>() }
            return HistoryPayload.search(query, records: records, directory: directory)
        }
        searchWork = work
        searchTask = Task { [weak self] in
            let matches = await work.value
            guard !Task.isCancelled else { return }
            self?.historyPanel?.showSearchResults(matches, for: query)
        }
    }

    private func pasteHistory(_ id: UUID) {
        guard !quitting, pasteTask == nil, let monitor, let board, let panel = historyPanel else { return }
        let target = self.target
        let observedVersion = board.changeCount
        pasteTask = Task {
            defer { pasteTask = nil }
            let representations: [[ClipboardSnapshot.Representation]]
            do {
                representations = try await monitor.representations(for: id)
            } catch {
                if !Task.isCancelled && panel.isVisible {
                    panel.showPasteFailure("记录无法读取。请选择其他记录或重新复制原内容。")
                }
                return
            }
            guard !Task.isCancelled, panel.isKeyWindow, NSApp.isActive,
                  panel.selectedEntryID == id else { return }
            guard monitor.contents.records.contains(where: { $0.id == id }) else {
                panel.showPasteFailure("这条记录已移出历史，请重新选择。")
                return
            }
            guard board.changeCount == observedVersion else {
                panel.showPasteFailure("剪贴板已被更新，请重新选择历史。")
                return
            }
            let files = representations.first?.first?.type == ClipboardFile.type
            var missingFiles = 0
            let version = ClipboardPaste.replace(representations, expectedVersion: observedVersion, prepare: {
                board.prepareForNewContents(with: [.currentHostOnly])
            }, write: { board.writeObjects($0) }, version: { board.changeCount },
                ignore: { monitor.ignoreOwnWrite($0) }, unavailableFiles: { missingFiles = $0 })
            guard let version else {
                if missingFiles > 0 {
                    panel.showPasteFailure("这条记录中有 \(missingFiles) 项文件或文件夹不可用。整组未粘贴。")
                } else {
                    panel.showPasteFailure("剪贴板写入失败，请重试。")
                }
                return
            }

            let screen = panel.screen
            closingToPaste = true
            panel.close()
            closingToPaste = false
            let result: ClipboardPaste.Result
            if !PasteTarget.hasPermission {
                HistoryLog.capture.notice("Paste fallback: Accessibility permission is unavailable")
                result = .permissionRequired
            } else if let target, environment?.ownsPasteboard == false {
                result = await target.sendPaste(files: files) {
                    !Task.isCancelled && board.changeCount == version
                }
            } else {
                result = .targetUnavailable
            }
            guard !Task.isCancelled else { return }
            if result == .targetUnavailable {
                HistoryLog.capture.info("Paste fallback: original focused input could not be verified")
            }
            if board.changeCount != version {
                pasteFeedback.show(.clipboardChanged, on: screen)
            } else {
                finishPaste(result, target: target, screen: screen)
            }
        }
    }

    private func finishPaste(_ result: ClipboardPaste.Result, target: PasteTarget?, screen: NSScreen?) {
        if result == .permissionRequired, environment?.showsPermissionGuide == true,
           !UserDefaults.standard.bool(forKey: Self.permissionGuideKey) {
            UserDefaults.standard.set(true, forKey: Self.permissionGuideKey)
            showingPermission = true
            let openSettings = pasteFeedback.showPermissionGuide()
            showingPermission = false
            if openSettings {
                PasteTarget.openPermissionSettings()
                return
            }
        }
        target?.restoreApplication()
        pasteFeedback.show(result, on: screen)
    }

    @objc private func openSettings() {
        closingToPaste = true
        historyPanel?.close()
        closingToPaste = false
        pasteTask?.cancel()
        let window = settingsWindow ?? SettingsWindow()
        settingsWindow = window
        window.updateShortcut(chord.label, available: shortcutAvailable)
        window.onShortcut = { [weak self] chord in self?.changeShortcut(chord) }
        window.onLogin = { [weak self] enabled in self?.changeLogin(enabled: enabled) }
        refreshLogin()
        window.updatePastePermission(PasteTarget.hasPermission)
        window.updateHistory(monitor?.contents, issue: monitor?.issue, samples: environment?.showsSamples == true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeShortcut(_ chord: ShortcutChord) -> GlobalShortcut {
        GlobalShortcut(chord: chord) { [weak self] in
            guard let self else { return }
            if let settingsWindow, settingsWindow.isRecordingShortcut {
                settingsWindow.finishShortcutRecording(chord)
            } else {
                toggleHistory()
            }
        }
    }

    private func changeShortcut(_ requested: ShortcutChord) {
        guard let settingsWindow else { return }
        let unchanged = "原组合 \(chord.label) 保留。"
        guard requested.isValid else {
            settingsWindow.showShortcutMessage("请按 Option + 空格，或用 Control、Option、Command 中至少一个键加字母或数字。\(unchanged)")
            return
        }
        if requested == chord, shortcutAvailable {
            settingsWindow.showShortcutMessage("当前组合为 \(chord.label)。")
            return
        }
        guard !requested.isReserved else {
            settingsWindow.showShortcutMessage("这个组合已被系统或常用操作占用。\(unchanged)")
            return
        }
        let candidate = makeShortcut(requested)
        guard candidate.register() == 0 else {
            settingsWindow.showShortcutMessage("这个组合暂不可用。\(unchanged)")
            return
        }
        if usesLiveSettings, let shortcutFile {
            do {
                let data = try JSONEncoder().encode(requested)
                try FileManager.default.createDirectory(at: shortcutFile.deletingLastPathComponent(),
                                                       withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                try data.write(to: shortcutFile, options: .atomic)
            } catch {
                candidate.unregister()
                settingsWindow.showShortcutMessage("快捷键未能保存。\(unchanged)")
                return
            }
        }
        shortcut?.unregister()
        shortcut = candidate
        shortcutAvailable = true
        chord = requested
        refreshPresentation()
        settingsWindow.updateShortcut(chord.label, available: true)
        settingsWindow.showShortcutMessage("已更新为 \(chord.label)。")
    }

    private func changeLogin(enabled: Bool) {
        guard usesLiveSettings else { return }
        let service = SMAppService.mainApp
        loginError = nil
        do {
            switch (enabled, service.status) {
            case (true, .enabled): break
            case (true, .requiresApproval): SMAppService.openSystemSettingsLoginItems()
            case (true, _): try service.register()
            case (false, .enabled), (false, .requiresApproval): try service.unregister()
            case (false, _): break
            }
        } catch {
            loginError = enabled ? "未能开启，请重试或查看系统设置。" : "未能关闭，请重试或查看系统设置。"
            HistoryLog.storage.error("Login item operation failed: \((error as NSError).code)")
        }
        refreshLogin()
    }

    private func refreshLogin() {
        settingsWindow?.updateLogin(usesLiveSettings ? SMAppService.mainApp.status : nil, error: loginError)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // Two offset pages and the short top-right strokes from the approved mark.
    private static func menuImage(hasIssue: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let pen = NSBezierPath()
            pen.lineWidth = 1.15
            pen.lineCapStyle = .round
            pen.lineJoinStyle = .round

            pen.move(to: NSPoint(x: 5, y: 5.5))
            pen.line(to: NSPoint(x: 3.5, y: 5.5))
            pen.curve(to: NSPoint(x: 2, y: 7), controlPoint1: NSPoint(x: 2.7, y: 5.5),
                      controlPoint2: NSPoint(x: 2, y: 6.2))
            pen.line(to: NSPoint(x: 2, y: 15))
            pen.curve(to: NSPoint(x: 3.5, y: 16.5), controlPoint1: NSPoint(x: 2, y: 15.8),
                      controlPoint2: NSPoint(x: 2.7, y: 16.5))
            pen.line(to: NSPoint(x: 11.5, y: 16.5))
            pen.curve(to: NSPoint(x: 13, y: 15), controlPoint1: NSPoint(x: 12.3, y: 16.5),
                      controlPoint2: NSPoint(x: 13, y: 15.8))

            pen.move(to: NSPoint(x: 12, y: 2))
            pen.line(to: NSPoint(x: 7.5, y: 2))
            pen.curve(to: NSPoint(x: 6, y: 3.5), controlPoint1: NSPoint(x: 6.7, y: 2),
                      controlPoint2: NSPoint(x: 6, y: 2.7))
            pen.line(to: NSPoint(x: 6, y: 11.5))
            pen.curve(to: NSPoint(x: 7.5, y: 13), controlPoint1: NSPoint(x: 6, y: 12.3),
                      controlPoint2: NSPoint(x: 6.7, y: 13))
            pen.line(to: NSPoint(x: 14.5, y: 13))
            pen.curve(to: NSPoint(x: 16, y: 11.5), controlPoint1: NSPoint(x: 15.3, y: 13),
                      controlPoint2: NSPoint(x: 16, y: 12.3))
            pen.line(to: NSPoint(x: 16, y: 6.5))

            pen.move(to: NSPoint(x: 14, y: 2))
            pen.line(to: NSPoint(x: 17, y: 2))
            pen.move(to: NSPoint(x: 15, y: 4))
            pen.line(to: NSPoint(x: 17, y: 4))
            NSColor.black.setStroke()
            pen.stroke()
            if hasIssue {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 14, y: 14, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
