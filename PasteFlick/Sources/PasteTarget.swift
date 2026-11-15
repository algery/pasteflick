import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
struct PasteTarget {
    private struct Focus: Equatable {
        enum Position: Equatable {
            case text(location: Int, length: Int)
            case folder(URL, selection: [AXUIElement])

            static func == (left: Self, right: Self) -> Bool {
                switch (left, right) {
                case let (.text(l1, n1), .text(l2, n2)): l1 == l2 && n1 == n2
                case let (.folder(u1, s1), .folder(u2, s2)):
                    u1 == u2 && s1.count == s2.count && zip(s1, s2).allSatisfy { CFEqual($0.0, $0.1) }
                default: false
                }
            }
        }

        let window: AXUIElement
        let element: AXUIElement
        let position: Position

        static func == (left: Focus, right: Focus) -> Bool {
            CFEqual(left.window, right.window) && CFEqual(left.element, right.element) &&
                left.position == right.position
        }
    }

    let application: NSRunningApplication
    private let focus: Focus?

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func capture() -> Self? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let trusted = hasPermission
        let focus = trusted ? focusedInput(in: application) : nil
        HistoryLog.capture.info("Paste target captured: AX=\(trusted), focused input=\(focus != nil)")
        return Self(application: application, focus: focus)
    }

    /// An already active external application is left alone. Returning from our own
    /// panel is the only circumstance in which we request activation.
    func restoreApplication() {
        guard !application.isTerminated, NSApp.isActive else { return }
        NSApp.yieldActivation(to: application)
        _ = application.activate()
    }

    func sendPaste(files: Bool = false, while valid: () -> Bool) async -> ClipboardPaste.Result {
        guard Self.hasPermission else { return .permissionRequired }
        guard !application.isTerminated, let focus, valid() else { return .targetUnavailable }
        if case .folder = focus.position, !files { return .targetUnavailable }
        restoreApplication()
        let deadline = ContinuousClock.now + .milliseconds(400)
        let workspace = NSWorkspace.shared
        let ownPID = ProcessInfo.processInfo.processIdentifier
        while !application.isActive {
            if let frontmost = workspace.frontmostApplication,
               frontmost.processIdentifier != ownPID,
               frontmost.processIdentifier != application.processIdentifier { return .targetUnavailable }
            guard valid(), ContinuousClock.now < deadline else { return .targetUnavailable }
            do { try await Task.sleep(for: .milliseconds(15)) }
            catch { return .targetUnavailable }
        }

        let ax = Self.accessibilityApplication(application)
        // Prefer the same keyboard command the user would issue. Some menus
        // acknowledge AXPress while the editor never receives the paste.
        if CGPreflightPostEventAccess(),
           let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
            down.flags = .maskCommand
            up.flags = .maskCommand
            guard Self.hasPermission else { return .permissionRequired }
            guard canPaste(into: focus, using: ax, while: valid) else { return .targetUnavailable }
            HistoryLog.capture.info("Paste requested through a targeted keyboard event")
            down.postToPid(application.processIdentifier)
            up.postToPid(application.processIdentifier)
            return .dispatched
        }

        let menuPaste = Self.pasteCommand(in: ax)
        guard Self.hasPermission else { return .permissionRequired }
        if let menuPaste {
            guard canPaste(into: focus, using: ax, while: valid) else { return .targetUnavailable }
            // Use the application's actual Command-V menu item. If its action gives
            // an ambiguous result, never send a second paste that could duplicate it.
            let outcome = AXUIElementPerformAction(menuPaste, kAXPressAction as CFString)
            if outcome == .success {
                HistoryLog.capture.info("Paste requested through the target application's Edit menu")
                return .dispatched
            }
            HistoryLog.capture.notice("Paste menu action failed: \(outcome.rawValue)")
            return Self.hasPermission ? .commandUnavailable : .permissionRequired
        }

        HistoryLog.capture.info("No verified Paste menu command and keyboard event access unavailable")
        return .commandUnavailable
    }

    private func canPaste(into focus: Focus, using ax: AXUIElement, while valid: () -> Bool) -> Bool {
        valid() && Self.focusedInput(in: application, ax: ax) == focus &&
            valid() && application.isActive && !application.isTerminated
    }

    private static func pasteCommand(in application: AXUIElement) -> AXUIElement? {
        let deadline = ContinuousClock.now + .milliseconds(180)
        guard let bar = element(attribute(kAXMenuBarAttribute, in: application)),
              attribute(kAXRoleAttribute, in: bar) as? String == kAXMenuBarRole else { return nil }
        var match: AXUIElement?
        for top in children(in: bar) {
            guard ContinuousClock.now < deadline else { return nil }
            guard attribute(kAXRoleAttribute, in: top) as? String == kAXMenuBarItemRole,
                  let title = attribute(kAXTitleAttribute, in: top) as? String,
                  ["Edit", "编辑", "編輯"].contains(title) else { continue }
            for menu in children(in: top) where attribute(kAXRoleAttribute, in: menu) as? String == kAXMenuRole {
                for item in children(in: menu) {
                    guard ContinuousClock.now < deadline else { return nil }
                    guard isPasteCommand(item) else { continue }
                    if match != nil { return nil }
                    match = item
                }
            }
        }
        return ContinuousClock.now < deadline ? match : nil
    }

    private static func isPasteCommand(_ item: AXUIElement) -> Bool {
        guard let title = attribute(kAXTitleAttribute, in: item) as? String,
              ["Paste", "粘贴", "貼上"].contains(title),
              attribute(kAXRoleAttribute, in: item) as? String == kAXMenuItemRole,
              let key = attribute(kAXMenuItemCmdCharAttribute, in: item) as? String,
              key.lowercased() == "v",
              (attribute(kAXMenuItemCmdModifiersAttribute, in: item) as? NSNumber)?.intValue == 0,
              (attribute(kAXEnabledAttribute, in: item) as? Bool) == true,
              children(in: item).isEmpty else { return false }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(item, &actions) == .success else { return false }
        return (actions as? [String])?.contains(kAXPressAction) == true
    }

    private static func children(in parent: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, in: parent) as? [AXUIElement] ?? []
    }

    static func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        if !NSWorkspace.shared.open(url) { NSSound.beep() }
    }

    private static func accessibilityApplication(_ application: NSRunningApplication) -> AXUIElement {
        let ax = AXUIElementCreateApplication(application.processIdentifier)
        return ax
    }

    private static func focusedInput(in application: NSRunningApplication, ax: AXUIElement? = nil) -> Focus? {
        guard application.isActive else { return nil }
        let ax = ax ?? accessibilityApplication(application)
        guard let window = element(attribute(kAXFocusedWindowAttribute, in: ax)),
              let input = element(attribute(kAXFocusedUIElementAttribute, in: ax)),
              (attribute(kAXSubroleAttribute, in: input) as? String) != kAXSecureTextFieldSubrole else { return nil }
        let position: Focus.Position
        if let selection = attribute(kAXSelectedTextRangeAttribute, in: input),
           CFGetTypeID(selection) == AXValueGetTypeID() {
            var range = CFRange()
            let value = unsafeDowncast(selection, to: AXValue.self)
            guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
            position = .text(location: range.location, length: range.length)
        } else if application.bundleIdentifier == "com.apple.finder",
                  let folder = finderPosition(window: window, input: input) {
            position = folder
        } else {
            return nil
        }
        guard let currentWindow = element(attribute(kAXFocusedWindowAttribute, in: ax)),
              let currentInput = element(attribute(kAXFocusedUIElementAttribute, in: ax)),
              CFEqual(window, currentWindow), CFEqual(input, currentInput) else { return nil }
        return Focus(window: window, element: input, position: position)
    }

    private static func finderPosition(window: AXUIElement, input: AXUIElement) -> Focus.Position? {
        let document = attribute(kAXDocumentAttribute, in: window) as? String
        let url = attribute(kAXURLAttribute, in: window) as? URL ?? document.flatMap(URL.init(string:))
        let role = attribute(kAXRoleAttribute, in: input) as? String
        guard let url, url.isFileURL, let role,
              [kAXListRole, kAXOutlineRole, kAXBrowserRole, kAXScrollAreaRole].contains(role) else { return nil }
        guard let selection = (attribute(kAXSelectedChildrenAttribute, in: input) as? [AXUIElement])
            ?? (attribute(kAXSelectedRowsAttribute, in: input) as? [AXUIElement]) else { return nil }
        return .folder(url, selection: selection)
    }

    private static func attribute(_ name: String, in element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
