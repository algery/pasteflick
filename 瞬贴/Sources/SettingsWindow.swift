import AppKit
import ServiceManagement
import Carbon.HIToolbox

@MainActor
final class SettingsWindow: NSWindow {
    private let shortcutControl = NSButton(title: "", target: nil, action: nil)
    private let loginControl = NSButton(checkboxWithTitle: "未开启", target: nil, action: nil)
    private let approveLogin = NSButton(title: "去系统设置…", target: nil, action: nil)
    private var chordLabel = ""
    private var shortcutAvailable = false
    private var recording = false
    private var feedback = ""
    var onShortcut: ((ShortcutChord) -> Void)?
    var onLogin: ((Bool) -> Void)?
    var isRecordingShortcut: Bool { isKeyWindow && recording }
    private let pasteStatus = Palette.label("", size: 12, color: Palette.muted)
    private let pastePermission = NSButton(title: "设置权限…", target: nil, action: nil)
    private let storageDetail = Palette.label("", size: 12, color: Palette.muted)
    private let storageRules = Palette.label("历史保存在这台 Mac 上，满了会淘汰最旧记录。", size: 12, color: Palette.muted)
    private let accessDetail = Palette.label("", size: 12, color: Palette.danger)
    private let openAccessSettings = NSButton(title: "打开系统设置…", target: nil, action: nil)
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Palette.width, height: 0),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        title = "瞬贴设置"
        identifier = NSUserInterfaceItemIdentifier("settings")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true

        let surface = Palette.fill(Palette.surface)
        contentView = surface
        guard let contents = surface.contentView else { return }

        let header = NSView()
        let heading = Palette.label(title, weight: .semibold)
        heading.alignment = .center
        header.addSubview(heading)
        heading.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            heading.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        let titleBar = Palette.fill(Palette.subtle)
        if let content = titleBar.contentView { Palette.place(header, in: content) }

        storageDetail.alignment = .left
        let storage = makeSection("本地历史", rows: [])
        storage.addArrangedSubview(storageDetail)
        storage.addArrangedSubview(storageRules)
        storage.addArrangedSubview(accessDetail)
        storage.addArrangedSubview(openAccessSettings)
        openAccessSettings.target = self
        openAccessSettings.action = #selector(showAccessSettings)
        openAccessSettings.bezelStyle = .rounded
        for label in [storageDetail, storageRules, accessDetail] {
            label.widthAnchor.constraint(equalTo: storage.widthAnchor).isActive = true
        }

        pastePermission.target = self
        pastePermission.action = #selector(showPastePermission)
        pastePermission.bezelStyle = .rounded
        shortcutControl.target = self
        shortcutControl.action = #selector(beginShortcut)
        shortcutControl.bezelStyle = .rounded
        shortcutControl.setAccessibilityLabel("修改唤起快捷键")
        loginControl.target = self
        loginControl.action = #selector(toggleLogin)
        loginControl.setAccessibilityLabel("登录后自动启动")
        loginControl.allowsMixedState = true
        approveLogin.target = self
        approveLogin.action = #selector(showLoginApproval)
        approveLogin.bezelStyle = .rounded
        approveLogin.isHidden = true
        let loginControls = NSStackView(views: [loginControl, approveLogin])
        let use = makeSection("使用", rows: [
                ("唤起剪贴板", "也可从菜单栏打开历史。", shortcutControl),
                ("登录后自动启动", "只在菜单栏运行，不弹出历史。", loginControls)
        ])
        let useFeedback = Palette.label("", size: 12, color: Palette.muted)
        useFeedback.maximumNumberOfLines = 3
        useFeedback.lineBreakMode = .byWordWrapping
        use.addArrangedSubview(useFeedback)
        useFeedback.widthAnchor.constraint(equalTo: use.widthAnchor).isActive = true
        self.useFeedback = useFeedback
        let pasteControls = NSStackView(views: [pasteStatus, pastePermission])
        pasteControls.spacing = 12
        let paste = makeSection("粘贴", rows: [("回车直接粘贴", nil, pasteControls)])
        let body = NSStackView(views: [use, paste, storage])
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 24

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        Palette.place(body, in: document, top: 24, left: 24, bottom: 24, right: 24)
        for section in body.arrangedSubviews {
            section.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        for view in [titleBar, scroll] {
            contents.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: contents.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: contents.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: contents.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 48),
            scroll.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: contents.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contents.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: contents.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        accessDetail.isHidden = true
        openAccessSettings.isHidden = true
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
        let width = min(Palette.width, (visible?.width ?? Palette.width + 32) - 32)
        let naturalHeight = 48 + body.fittingSize.height + 112
        setContentSize(NSSize(width: width, height: min(naturalHeight, (visible?.height ?? naturalHeight + 32) - 32)))
        center()
    }

    func updateHistory(_ contents: HistoryContents?, issue: HistoryIssue?, samples: Bool) {
        if let contents, issue != .starting, issue != .historyUnavailable {
            let mb = Double(contents.bytes) / 1_000_000
            let size = mb > 0 && mb < 0.1 ? "< 0.1" : mb.formatted(.number.precision(.fractionLength(0...1)))
            storageDetail.stringValue = "\(contents.records.count) / \(HistoryLimits.standard.count) 条 · \(size) MB / 1 GB"
        } else {
            storageDetail.stringValue = samples ? "虚构样例仅供演示。" : issue?.title ?? "正在读取历史"
        }
        accessDetail.stringValue = "在系统设置 → 隐私与安全性 → 剪贴板中允许瞬贴读取。"
        accessDetail.isHidden = issue?.isPermission != true
        openAccessSettings.isHidden = issue?.isPermission != true
    }

    @objc private func showAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") else { return }
        if !NSWorkspace.shared.open(url) { NSSound.beep() }
    }

    private weak var useFeedback: NSTextField?
    private var loginStatus: SMAppService.Status?
    private var loginMessage = ""

    func updateShortcut(_ label: String, available: Bool) {
        chordLabel = label
        shortcutAvailable = available
        refreshControl()
    }

    func showShortcutMessage(_ message: String) {
        feedback = message
        refreshControl()
    }

    func finishShortcutRecording(_ chord: ShortcutChord) {
        recording = false
        onShortcut?(chord)
    }

    private func refreshControl() {
        shortcutControl.title = recording ? "请按组合键…" : chordLabel
        let shortcutMessage = feedback.isEmpty && !shortcutAvailable ? "当前组合暂不可用，仍可从菜单栏打开历史。" : feedback
        useFeedback?.stringValue = [shortcutMessage, loginMessage].filter { !$0.isEmpty }.joined(separator: "\n")
        useFeedback?.isHidden = useFeedback?.stringValue.isEmpty == true
    }

    @objc private func beginShortcut() {
        recording = true
        showShortcutMessage("按 Esc 取消。")
    }

    override func sendEvent(_ event: NSEvent) {
        guard recording, event.type == .keyDown else { super.sendEvent(event); return }
        if event.isARepeat { return }
        recording = false
        if event.keyCode == UInt16(kVK_Escape) {
            showShortcutMessage("已取消，原快捷键保留。")
        } else {
            finishShortcutRecording(ShortcutChord(event))
        }
    }

    override func resignKey() {
        super.resignKey()
        if recording {
            recording = false
            showShortcutMessage("已取消，原快捷键保留。")
        }
    }

    @objc private func toggleLogin() {
        onLogin?(loginStatus == .notRegistered)
    }

    @objc private func showLoginApproval() { SMAppService.openSystemSettingsLoginItems() }

    func updateLogin(_ status: SMAppService.Status?, error: String?) {
        loginStatus = status
        loginControl.isEnabled = status != nil && status != .notFound
        approveLogin.isHidden = status != .requiresApproval
        loginControl.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginControl.title = switch status {
        case .enabled: "已开启"
        case .requiresApproval: "待允许"
        case .notRegistered: "已关闭"
        default: "不可用"
        }
        loginMessage = error ?? (status == .requiresApproval ? "等待系统允许，当前尚未开启。" : "")
        refreshControl()
    }

    func updatePastePermission(_ allowed: Bool) {
        pasteStatus.stringValue = allowed ? "已允许" : "尚未允许 · 回车后按 ⌘V"
        pastePermission.isHidden = allowed
    }

    @objc private func showPastePermission() { PasteTarget.openPermissionSettings() }

    override func cancelOperation(_ sender: Any?) { close() }

    private func makeSection(_ name: String, rows: [(name: String, detail: String?, status: NSView?)]) -> NSStackView {
        let title = Palette.label(name, size: 12, weight: .medium, color: Palette.muted)
        let section = NSStackView(views: [title])
        section.orientation = .vertical
        section.alignment = .width
        section.spacing = 4
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = Palette.fill(Palette.line)
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                section.addArrangedSubview(line)
            }
            section.addArrangedSubview(makeRow(row.name, detail: row.detail, status: row.status))
        }
        for view in section.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    private func makeRow(_ name: String, detail: String?, status: NSView?) -> NSView {
        let row = NSView()
        let copy = NSStackView(views: [Palette.label(name)])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 4
        if let detail { copy.addArrangedSubview(Palette.label(detail, size: 12, color: Palette.muted)) }

        row.addSubview(copy)
        copy.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            copy.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            copy.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 64)
        ])
        if let badge = status {
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addSubview(badge)
            badge.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                copy.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -16)
            ])
        } else {
            copy.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
        }
        return row
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
