import AppKit
import Carbon.HIToolbox

struct ShortcutChord: Codable, Equatable {
    let code: UInt32
    let modifiers: UInt32
    static let defaultChord = Self(code: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))

    private static let keys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1",
        kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
        kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9"
    ]
    private static let modifierKeys: [(NSEvent.ModifierFlags, Int, String)] = [
        (.control, controlKey, "⌃"), (.option, optionKey, "⌥"),
        (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")
    ]

    init(code: UInt32, modifiers: UInt32) {
        self.code = code
        self.modifiers = modifiers
    }

    @MainActor
    init(_ event: NSEvent) {
        code = UInt32(event.keyCode)
        modifiers = Self.modifierKeys.reduce(into: 0) { mask, key in
            if event.modifierFlags.contains(key.0) { mask |= UInt32(key.1) }
        }
    }

    var isValid: Bool {
        if code == UInt32(kVK_Space) { return modifiers == UInt32(optionKey) }
        return Self.keys[Int(code)] != nil &&
            modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 &&
            modifiers & ~UInt32(controlKey | optionKey | cmdKey | shiftKey) == 0
    }

    var isReserved: Bool {
        modifiers == UInt32(cmdKey) &&
            [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z,
             kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_H, kVK_ANSI_M].contains(Int(code))
    }

    var label: String {
        Self.modifierKeys.filter { modifiers & UInt32($0.1) != 0 }.map { $0.2 }.joined()
            + (code == UInt32(kVK_Space) ? "空格" : Self.keys[Int(code)] ?? "")
    }
}

@MainActor
final class GlobalShortcut {
    private static var nextID: UInt32 = 0
    private let identifier: EventHotKeyID
    let chord: ShortcutChord
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed = false
    private let action: () -> Void

    init(chord: ShortcutChord = .defaultChord, action: @escaping () -> Void) {
        Self.nextID &+= 1
        identifier = EventHotKeyID(signature: 0x53485445, id: Self.nextID)
        self.chord = chord
        self.action = action
    }

    func register() -> OSStatus {
        guard registration == nil else { return noErr }
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let target = GetApplicationEventTarget()
        let status = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
            )
            guard result == noErr else { return OSStatus(eventNotHandledErr) }
            let eventKind = GetEventKind(event)
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { shortcut.handle(identifier, eventKind: eventKind) }
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)

        guard status == noErr else { return status }
        let registered = RegisterEventHotKey(chord.code, chord.modifiers,
                                             identifier, target, UInt32(kEventHotKeyExclusive), &registration)
        if registered != noErr { unregister() }
        return registered
    }

    func unregister() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
        pressed = false
    }

    private func handle(_ identifier: EventHotKeyID, eventKind: UInt32) -> OSStatus {
        guard identifier.signature == self.identifier.signature, identifier.id == self.identifier.id else {
            return OSStatus(eventNotHandledErr)
        }
        if eventKind == UInt32(kEventHotKeyReleased) {
            pressed = false
        } else if !pressed {
            pressed = true
            action()
        }
        return noErr
    }
}
