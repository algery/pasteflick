import AppKit

@MainActor
final class HistoryPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var history = History()
    private let table = HistoryTable()
    private let searchField = NSTextField()
    private let hotkey = Palette.label("", size: 12, color: Palette.muted)
    private let keyHints = Palette.label("Esc 关闭", size: 11, color: Palette.muted)
    private var allEntries: [HistoryEntry] = []
    private var query = ""
    private var searching = false
    private enum Category: String, CaseIterable {
        case all = "全部", words = "文字与链接", image = "图片", file = "文件"
        func includes(_ kind: HistoryEntry.Kind) -> Bool {
            switch self {
            case .all: true
            case .words: kind == .text || kind == .link
            case .image: kind == .image
            case .file: kind == .file || kind == .folder
            }
        }
    }
    private var category = Category.all
    private var matchedIDs = Set<UUID>()
    private let preview = PreviewScroll()
    private var previewTask: Task<Void, Never>?
    private var previewID: UUID?
    private var previewReady = false
    private let thumbnails: HistoryThumbnailLoader?
    var onSearch: ((String) -> Void)?
    var onPaste: ((UUID) -> Void)?
    var onClose: (() -> Void)?
    var loadPreview: ((UUID) async throws -> [[ClipboardSnapshot.Representation]])?
    override func becomeKey() {
        super.becomeKey()
        if firstResponder == nil || firstResponder == self { searchField.selectText(nil) }
    }
    var selectedEntryID: UUID? {
        if let previewID { return previewReady ? previewID : nil }
        let row = table.selectedRow
        guard !searching, history.entries.indices.contains(row) else { return nil }
        return history.entries[row].id
    }
    private let scroll = NSScrollView()
    private let categories = NSStackView()
    private let noticeHeight: CGFloat = 64
    private let notice = Palette.fill(Palette.subtle, radius: 8)
    private let noticeTitle = Palette.label("", weight: .semibold, color: Palette.danger)
    private let noticeDetail = Palette.label("", size: 12, color: Palette.muted)
    private let noticeAction = NSButton(title: "", target: nil, action: nil)
    private let emptyDetail = Palette.label("复制的内容会出现在这里。", size: 12, color: Palette.muted)
    private var presentedIssue: HistoryIssue?
    private var presentationScreen: NSScreen?
    private var samples = false
    var onRetry: (() -> Void)?
    var onSettings: (() -> Void)?
    private let total = Palette.label("0 条", size: 11, color: Palette.muted)
    private let empty = Palette.label("还没有复制记录", size: 15, weight: .medium)

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(thumbnails: HistoryThumbnailLoader? = nil) {
        self.thumbnails = thumbnails
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Palette.width, height: Palette.panelHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        title = "瞬贴剪贴板"
        identifier = NSUserInterfaceItemIdentifier("history")
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0

        let search = NSView()
        let searchIcon = Palette.icon("magnifyingglass")
        searchField.placeholderString = "搜索剪贴板"
        searchField.font = .systemFont(ofSize: 18)
        searchField.textColor = Palette.text
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.delegate = self
        searchField.setAccessibilityLabel("搜索剪贴板")
        searchField.identifier = NSUserInterfaceItemIdentifier("historySearch")
        hotkey.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = Palette.fill(Palette.line)
        for child in [searchIcon, searchField, hotkey, line] {
            search.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            search.heightAnchor.constraint(equalToConstant: Palette.searchHeight),
            searchIcon.leadingAnchor.constraint(equalTo: search.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 20),
            searchField.leadingAnchor.constraint(equalTo: search.leadingAnchor, constant: 46),
            searchField.trailingAnchor.constraint(equalTo: hotkey.leadingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            hotkey.trailingAnchor.constraint(equalTo: search.trailingAnchor, constant: -16),
            hotkey.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.bottomAnchor.constraint(equalTo: search.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: search.trailingAnchor)
        ])

        let categoryBar = NSView()
        categories.orientation = .horizontal
        categories.alignment = .centerY
        categories.spacing = 4
        categoryBar.addSubview(categories)
        categories.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            categoryBar.heightAnchor.constraint(equalToConstant: Palette.categoryHeight),
            categories.leadingAnchor.constraint(equalTo: categoryBar.leadingAnchor, constant: 16),
            categories.centerYAnchor.constraint(equalTo: categoryBar.centerYAnchor)
        ])

        let results = NSView()
        let maxHeight = results.heightAnchor.constraint(equalToConstant: Palette.historyHeight)
        maxHeight.priority = .defaultHigh
        maxHeight.isActive = true
        configureTable()
        Palette.place(scroll, in: results, left: 8, right: 8)
        preview.isHidden = true
        preview.drawsBackground = false
        preview.hasVerticalScroller = true
        preview.autohidesScrollers = true
        Palette.place(preview, in: results, top: 10, left: 20, bottom: 8, right: 20)
        let emptyState = NSStackView(views: [empty, emptyDetail])
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        results.addSubview(emptyState)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: results.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: results.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: results.leadingAnchor, constant: 16)

        ])

        let footer = NSView()
        for child in [total, keyHints] {
            footer.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            footer.heightAnchor.constraint(equalToConstant: Palette.footerHeight),
            total.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            total.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            keyHints.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            keyHints.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        let noticeRow = NSView()
        configureNotice()
        Palette.place(notice, in: noticeRow, top: 8, left: 16, right: 16)
        noticeRow.heightAnchor.constraint(greaterThanOrEqualToConstant: noticeHeight).isActive = true
        noticeRow.isHidden = true

        for section in [search, noticeRow, categoryBar, results, footer] {
            stack.addArrangedSubview(section)
        }
        let surface = Palette.fill(Palette.surface, radius: Palette.radius)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Palette.radius
        surface.layer?.masksToBounds = true
        if let contents = surface.contentView { Palette.place(stack, in: contents) }
        contentView = surface
    }

    func show(entries: [HistoryEntry], samples: Bool, on screen: NSScreen?, issue: HistoryIssue? = nil, shortcut: String = "") {
        if !isVisible {
            history.open(entries: entries)
            searchField.stringValue = ""
            query = ""
            category = .all
            matchedIDs = []
            self.samples = samples
            presentationScreen = screen
        }
        hotkey.stringValue = shortcut
        refresh(entries: entries, issue: issue)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func refresh(entries: [HistoryEntry], issue: HistoryIssue?) {
        allEntries = entries
        if let previewID, !entries.contains(where: { $0.id == previewID }) { dismissPreview() }
        updateIssue(issue)
        applyQuery()
    }

    func showSearchResults(_ ids: Set<UUID>, for query: String) {
        guard isVisible, query == self.query else { return }
        matchedIDs = ids
        render(allEntries.filter { $0.id.map(ids.contains) == true }, searching: false)
    }

    private func applyQuery(resetSelection: Bool = false) {
        if query.isEmpty {
            render(allEntries, searching: false, resetSelection: resetSelection)
            onSearch?("")
        } else if samples {
            let matches = allEntries.filter { ($0.kind == .text || $0.kind == .link) &&
                $0.title.range(of: query, options: .caseInsensitive) != nil }
            render(matches, searching: false, resetSelection: resetSelection)
        } else {
            if resetSelection { matchedIDs = [] }
            let visible = allEntries.filter { $0.id.map(matchedIDs.contains) == true }
            render(visible, searching: true, resetSelection: resetSelection)
            onSearch?(query)
        }
    }

    private func render(_ matches: [HistoryEntry], searching: Bool, resetSelection: Bool = false) {
        let entries = matches.filter { category.includes($0.kind) }
        self.searching = searching
        let oldSelection = table.selectedRow
        let selectedID = history.entries.indices.contains(oldSelection) ? history.entries[oldSelection].id : nil
        let loading = presentedIssue == .starting || presentedIssue == .historyUnavailable
        history.refresh(entries: entries)
        total.stringValue = samples ? "\(entries.count) 条 · 虚构样例" : "\(entries.count) 条"
        if loading { total.stringValue = presentedIssue?.title ?? "" }
        refreshCategories(allEntries, unavailable: loading)
        if loading { empty.stringValue = presentedIssue?.title ?? "" }
        else if searching { empty.stringValue = "正在查找…" }
        else { empty.stringValue = query.isEmpty && category == .all ? "还没有复制记录" : "没有找到" }
        empty.isHidden = !entries.isEmpty || previewID != nil
        emptyDetail.isHidden = !entries.isEmpty || loading || !query.isEmpty || category != .all || previewID != nil
        if previewID != nil {
            keyHints.stringValue = previewReady ? "Esc 返回    ⌘F 搜索    ↵ 粘贴" : "Esc 返回    ⌘F 搜索"
        } else if !searching && entries.contains(where: { $0.id != nil }) {
            keyHints.stringValue = "↓ 选择    ←→ 分类    空格预览    ↵ 粘贴"
        } else {
            keyHints.stringValue = "↓ 列表    ←→ 分类    Esc 关闭"
        }
        scroll.isHidden = previewID != nil
        table.reloadData()
        if !entries.isEmpty {
            let row = resetSelection ? 0 : selectedID.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if resetSelection || oldSelection < 0 { table.scrollRowToVisible(row) }
        }
    }

    private func updateIssue(_ issue: HistoryIssue?) {
        let hadNotice = shouldShowNotice(presentedIssue)
        presentedIssue = issue
        noticeTitle.stringValue = issue?.title ?? ""
        noticeDetail.stringValue = issue?.detail ?? ""
        let showAction = issue == .historyUnavailable || issue == .permissionRequired
        noticeAction.isHidden = !showAction
        noticeAction.title = issue == .historyUnavailable ? "重试" : "查看设置"
        let showNotice = shouldShowNotice(issue)
        notice.superview?.isHidden = !showNotice
        if !isVisible || hadNotice != showNotice {
            let target = isVisible ? screen ?? presentationScreen : presentationScreen
            position(on: target, showNotice: showNotice)
        }
    }

    private func shouldShowNotice(_ issue: HistoryIssue?) -> Bool {
        issue != nil && issue != .starting
    }

    private func configureNotice() {
        guard let contents = notice.contentView else { return }
        noticeAction.target = self
        noticeAction.action = #selector(handleNotice)
        noticeAction.bezelStyle = .rounded
        let text = NSStackView(views: [noticeTitle, noticeDetail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let line = NSStackView(views: [text, noticeAction])
        line.alignment = .centerY
        line.spacing = 16
        line.setHuggingPriority(.defaultHigh, for: .horizontal)
        noticeAction.setContentCompressionResistancePriority(.required, for: .horizontal)
        noticeDetail.maximumNumberOfLines = 2
        noticeDetail.lineBreakMode = .byWordWrapping
        Palette.place(line, in: contents, top: 8, left: 12, bottom: 8, right: 12)
    }

    @objc private func handleNotice() {
        if presentedIssue == .historyUnavailable { onRetry?() }
        if presentedIssue == .permissionRequired { onSettings?() }
    }

    func showPasteFailure(_ message: String) {
        updateIssue(.pasteFailure(message))
    }

    override func close() {
        guard history.isOpen else { super.close(); return }
        clearPreview()
        history.close()
        super.close()
        query = ""
        allEntries = []
        table.reloadData()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        if previewID != nil { dismissPreview() } else { close() }
    }

    override func sendEvent(_ event: NSEvent) {
        // AppKit can leave focus on the panel itself while switching the preview document view.
        if event.type == .keyDown, previewID != nil,
           firstResponder === self || firstResponder === preview ||
               (firstResponder as? NSView)?.isDescendant(of: preview) == true,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}" {
            pasteSelected()
            return
        }
        super.sendEvent(event)
    }

    private func position(on screen: NSScreen?, showNotice: Bool) {
        guard let visible = screen?.visibleFrame else { return }
        let width = min(Palette.width, visible.width - 32)
        let naturalHeight = Palette.panelHeight + (showNotice ? noticeHeight : 0)
        let height = min(naturalHeight, visible.height - 32)
        setFrame(
            NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
            display: false
        )
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if previewID != nil {
            clearPreview()
            applyQuery()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if previewID != nil {
            clearPreview()
            applyQuery()
        }
        syncQuery()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            syncQuery()
            if !history.entries.isEmpty {
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                table.scrollRowToVisible(0)
            }
            makeFirstResponder(table)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            makeFirstResponder(table)
        case #selector(NSResponder.insertNewline(_:)):
            syncQuery()
            if NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty != false {
                pasteSelected()
            }
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default: return false
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == ",",
           (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            onSettings?()
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f",
           (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            if previewID != nil { dismissPreview() }
            makeFirstResponder(searchField)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func syncQuery() {
        let edited = (searchField.currentEditor() as? NSTextView)?.string ?? searchField.stringValue
        let term = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != term else { return }
        if previewID != nil { clearPreview() }
        query = term
        applyQuery(resetSelection: true)
    }

    private func pasteSelected() {
        if let id = selectedEntryID { onPaste?(id) }
    }

    private func changeCategory(_ offset: Int) {
        let choices = Category.allCases
        guard let index = choices.firstIndex(of: category) else { return }
        selectCategory(choices[(index + offset + choices.count) % choices.count])
    }

    private func selectCategory(_ choice: Category) {
        if previewID != nil { clearPreview() }
        category = choice
        if !query.isEmpty && !samples {
            render(allEntries.filter { $0.id.map(matchedIDs.contains) == true }, searching: searching)
        } else {
            applyQuery()
        }
        makeFirstResponder(table)
    }

    private func openPreview() {
        guard let id = selectedEntryID, let loadPreview,
              let entry = allEntries.first(where: { $0.id == id }) else { return }
        clearPreview()
        previewID = id
        preview.isHidden = false
        scroll.isHidden = true
        empty.isHidden = true
        emptyDetail.isHidden = true
        keyHints.stringValue = "Esc 返回    ⌘F 搜索"
        showPreviewText(NSAttributedString(string: "正在读取预览…"))
        makeFirstResponder(preview)
        previewTask = Task { [weak self] in
            do {
                let items = try await loadPreview(id)
                if entry.kind == .image && items.count == 1 {
                    guard let self, let image = await thumbnails?.previewImage(in: items) else {
                        throw HistoryPayload.Failure.invalid
                    }
                    guard !Task.isCancelled, previewID == id else { return }
                    showPreviewImage(image)
                    markPreviewReady()
                } else {
                    guard let self, !Task.isCancelled, previewID == id else { return }
                    let text: NSAttributedString?
                    var fileUnavailable = false
                    if entry.kind == .file || entry.kind == .folder {
                        let files = ClipboardFile.from(items)
                        guard files.count == items.count else { throw HistoryPayload.Failure.invalid }
                        let details = files.map { file in
                            let base = "\(file.name)\n\(file.url.path)"
                            if file.isLocallyAvailable { return base }
                            fileUnavailable = true
                            return base + "\n此项不可用 · 整组暂不能粘贴"
                        }
                        text = NSAttributedString(string: details.joined(separator: "\n\n"),
                                                  attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Palette.text])
                    } else {
                        text = HistoryPayload.previewText(items)
                    }
                    guard let text else { throw HistoryPayload.Failure.invalid }
                    showPreviewText(text)
                    if !fileUnavailable { markPreviewReady() }
                }
            } catch {
                guard let self, !Task.isCancelled, previewID == id else { return }
                showPreviewText(NSAttributedString(string: "暂时无法预览这条内容。按 Esc 返回后可重试。",
                                                   attributes: [.foregroundColor: Palette.text]))
            }
        }
    }

    private func markPreviewReady() {
        previewReady = true
        keyHints.stringValue = "Esc 返回    ⌘F 搜索    ↵ 粘贴"
    }

    private func showPreviewText(_ text: NSAttributedString) {
        let size = preview.contentSize
        let view = NSTextView(frame: NSRect(origin: .zero, size: size))
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(text)
        preview.documentView = view
        view.scrollToBeginningOfDocument(nil)
    }

    private func showPreviewImage(_ image: CGImage) {
        let width = min(max(1, preview.contentSize.width), CGFloat(image.width))
        let height = width * CGFloat(image.height) / CGFloat(image.width)
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.image = NSImage(cgImage: image, size: .zero)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("图片预览")
        preview.documentView = view
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewID = nil
        previewReady = false
        preview.isHidden = true
        preview.documentView = nil
    }

    private func dismissPreview() {
        clearPreview()
        if !query.isEmpty && !samples {
            render(allEntries.filter { $0.id.map(matchedIDs.contains) == true }, searching: searching)
        } else {
            applyQuery()
        }
        makeFirstResponder(table)
    }

    private func configureTable() {
        table.onReturn = { [weak self] in self?.pasteSelected() }
        table.onEscape = { [weak self] in self?.close() }
        table.onSpace = { [weak self] in self?.openPreview() }
        table.onCategory = { [weak self] offset in self?.changeCategory(offset) }
        table.onTab = { [weak self] in
            guard let self else { return }
            self.makeFirstResponder(self.searchField)
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = Palette.rowHeight
        table.usesAutomaticRowHeights = false
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.setAccessibilityLabel("复制历史")
        table.dataSource = self
        table.delegate = self

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
    }

    private func refreshCategories(_ entries: [HistoryEntry], unavailable: Bool) {
        for item in categories.arrangedSubviews { item.removeFromSuperview() }

        for candidate in Category.allCases {
            let active = candidate == category
            let color = active ? Palette.accent : Palette.muted
            let title = Palette.label(candidate.rawValue, size: 12, weight: active ? .semibold : .medium, color: color)
            let count = Palette.label(unavailable ? "—" : String(entries.count { candidate.includes($0.kind) }),
                                      size: 11, color: color)
            title.setAccessibilityLabel(active ? "\(candidate.rawValue)，已选" : candidate.rawValue)
            count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            let item = CategoryControl()
            item.setAccessibilityElement(true)
            item.setAccessibilityRole(.button)
            item.setAccessibilityLabel(active ? "\(candidate.rawValue)，已选" : candidate.rawValue)
            item.select = { [weak self] in self?.selectCategory(candidate) }
            let labels = NSStackView(views: [title, count])
            labels.spacing = 8
            item.addSubview(labels)
            labels.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                item.heightAnchor.constraint(equalToConstant: 40),
                item.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
                labels.centerXAnchor.constraint(equalTo: item.centerXAnchor),
                labels.centerYAnchor.constraint(equalTo: item.centerYAnchor),
                labels.leadingAnchor.constraint(greaterThanOrEqualTo: item.leadingAnchor, constant: 12)
            ])
            if active {
                let underline = Palette.fill(Palette.accent, radius: 1)
                item.addSubview(underline)
                underline.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    underline.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: 12),
                    underline.trailingAnchor.constraint(equalTo: item.trailingAnchor, constant: -12),
                    underline.bottomAnchor.constraint(equalTo: item.bottomAnchor),
                    underline.heightAnchor.constraint(equalToConstant: 2)
                ])
            }
            categories.addArrangedSubview(item)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { history.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = history.entries[row]
        let cell = HistoryCell()
        let icon = Palette.icon(entry.kind.symbol, size: 16)
        let title = Palette.label(entry.title)
        let time = Palette.label(entry.time, size: 11, color: Palette.muted)
        time.alignment = .right
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        if let resource = entry.image,
           let url = Bundle.main.url(forResource: resource, withExtension: "svg"),
           let thumbnail = NSImage(contentsOf: url) {
            cell.showThumbnail(thumbnail, in: icon)
        } else if entry.kind == .image, let id = entry.id, let thumbnails {
            cell.thumbnailTask = Task { [weak cell, weak icon] in
                guard let image = await thumbnails.image(for: id), !Task.isCancelled, let icon else { return }
                let thumbnail = NSImage(cgImage: image, size: .zero)
                cell?.showThumbnail(thumbnail, in: icon)
            }
        }
        cell.textField = title
        cell.imageView = icon
        for child in [icon, title, time] {
            cell.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -12),
            time.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            time.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            time.widthAnchor.constraint(equalToConstant: 64)
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HistoryRowView()
    }
}

@MainActor
private final class CategoryControl: NSView {
    var select: (() -> Void)?
    override func mouseDown(with event: NSEvent) { select?() }
    override func accessibilityPerformPress() -> Bool { select?(); return true }
}

@MainActor
private final class HistoryCell: NSTableCellView {
    var thumbnailTask: Task<Void, Never>?

    deinit { thumbnailTask?.cancel() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { thumbnailTask?.cancel() }
    }

    func showThumbnail(_ thumbnail: NSImage, in icon: NSImageView) {
        icon.image = thumbnail
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 4
        icon.layer?.masksToBounds = true
    }
}

@MainActor
private final class HistoryTable: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSpace: (() -> Void)?
    var onCategory: ((Int) -> Void)?
    var onTab: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "\r", "\u{3}":
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { onReturn?() }
        case "\u{1B}": onEscape?()
        case " ": onSpace?()
        case "\u{F702}": onCategory?(-1)
        case "\u{F703}": onCategory?(1)
        case "\t", "\u{19}": onTab?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class PreviewScroll: NSScrollView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "\u{1B}": window?.cancelOperation(nil)
        case "\t", "\u{19}": break
        case "\u{F700}": scrollLineUp(nil)
        case "\u{F701}": scrollLineDown(nil)
        case "\u{F72C}": scrollPageUp(nil)
        case "\u{F72D}": scrollPageDown(nil)
        case "\u{F729}": scrollToBeginningOfDocument(nil)
        case "\u{F72B}": scrollToEndOfDocument(nil)
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class HistoryRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            for column in 0..<numberOfColumns {
                guard let cell = view(atColumn: column) as? NSTableCellView else { continue }
                cell.textField?.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
            }
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Palette.selection.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
