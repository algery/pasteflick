import AppKit

@MainActor
final class PasteFeedback {
    private var toast: NSPanel?
    private var dismissal: Task<Void, Never>?

    func clear() {
        dismissal?.cancel()
        dismissal = nil
        toast?.close()
        toast = nil
    }

    func show(_ result: ClipboardPaste.Result, on screen: NSScreen?) {
        let text: String
        switch result {
        case .permissionRequired: text = "辅助功能权限未生效。已复制，请按 ⌘V 粘贴"
        case .targetUnavailable: text = "原输入位置已变化。已复制，请按 ⌘V 粘贴"
        case .commandUnavailable: text = "无法调用原应用的粘贴命令。已复制，请按 ⌘V 粘贴"
        case .clipboardChanged: text = "剪贴板已被更新，请重新选择历史"
        case .dispatched: return
        }
        clear()
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let label = Palette.label(text)
        let width = label.fittingSize.width + 36
        let panel = NSPanel(
            contentRect: NSRect(x: frame.midX - width / 2, y: frame.minY + 88, width: width, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let fill = Palette.fill(Palette.surface, radius: 10)
        if let content = fill.contentView {
            label.alignment = .center
            Palette.place(label, in: content, left: 18, right: 18)
        }
        panel.contentView = fill
        toast = panel
        panel.orderFrontRegardless()
        NSAccessibility.post(element: label, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3.5)) }
            catch { return }
            self?.clear()
        }
    }

    func showPermissionGuide() -> Bool {
        let alert = NSAlert()
        alert.messageText = "让回车直接完成粘贴"
        alert.informativeText = "这条内容已复制。允许瞬贴使用辅助功能后，回车即可把内容贴回原来的输入位置。你也可以回到原窗口按 ⌘V。"
        alert.addButton(withTitle: "打开辅助功能设置")
        let manual = alert.addButton(withTitle: "先手动粘贴")
        manual.keyEquivalent = "\u{1B}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
