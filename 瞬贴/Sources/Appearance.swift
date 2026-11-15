import AppKit

@MainActor
enum Palette {
    static let width: CGFloat = 640
    static let rowHeight: CGFloat = 40
    static let radius: CGFloat = 16
    static let historyHeight = rowHeight * CGFloat(History.defaultRowCount)
    static let searchHeight: CGFloat = 64
    static let categoryHeight: CGFloat = 44
    static let footerHeight: CGFloat = 40
    static let panelHeight = searchHeight + categoryHeight + historyHeight + footerHeight

    static let surface = color(0xFFFFFF, 0x242426)
    static let subtle = color(0xF7F7F9, 0x2C2C2F)
    static let text = color(0x333333, 0xF1F1F3)
    static let muted = color(0x66666D, 0xAAAAAF)
    static let accent = color(0x0070C9, 0x79B8FF)
    static let selection = color(0xEBF4FC, 0x273B50)
    static let danger = color(0xB42318, 0xFFB4AB)
    static let line = color(0xE9E9ED, 0x39393D)

    private static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255,
                alpha: 1
            )
        }
    }

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = Palette.text) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func fill(_ color: NSColor, radius: CGFloat = 0, content: NSView? = nil) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        box.cornerRadius = radius
        box.fillColor = color
        if let content { box.contentView = content }
        return box
    }

    static func place(_ child: NSView, in parent: NSView, top: CGFloat = 0, left: CGFloat = 0,
                      bottom: CGFloat = 0, right: CGFloat = 0) {
        parent.addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: top),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: left),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -bottom),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -right)
        ])
    }

    static func icon(_ name: String, size: CGFloat = 18) -> NSImageView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image.symbolConfiguration = .init(pointSize: size, weight: .regular)
        image.contentTintColor = muted
        return image
    }
}
