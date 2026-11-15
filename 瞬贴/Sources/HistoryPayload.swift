import AppKit
import CoreFoundation
import ImageIO

enum HistoryPayload {
    enum Failure: Error { case invalid, missingRepresentation }
    private static let htmlBlockElements: Set<String> = [
        "address", "article", "blockquote", "br", "div", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "li", "p", "pre", "section", "td", "th", "tr"
    ]

    static func decode(_ data: Data) throws -> [[ClipboardSnapshot.Representation]] {
        var reader = Reader(data: data)
        let itemCount = try reader.count()
        guard itemCount > 0, itemCount <= reader.remaining / 8 else { throw Failure.invalid }
        var items: [[ClipboardSnapshot.Representation]] = []
        for _ in 0..<itemCount {
            let formatCount = try reader.count()
            guard formatCount > 0, formatCount <= reader.remaining / 16 else { throw Failure.invalid }
            var formats: [ClipboardSnapshot.Representation] = []
            var types = Set<String>()
            for _ in 0..<formatCount {
                let width = try reader.count()
                guard width > 0, width <= 512 else { throw Failure.invalid }
                let type = try reader.bytes(width)
                guard let name = String(data: type, encoding: .utf8), types.insert(name).inserted else {
                    throw Failure.invalid
                }
                let length = try reader.count()
                let bytes = try reader.bytes(length)
                formats.append(.init(type: name, data: bytes))
            }
            items.append(formats)
        }
        guard reader.remaining == 0 else { throw Failure.invalid }
        return items
    }

    static func matches(_ items: [[ClipboardSnapshot.Representation]], kind: HistoryEntry.Kind, query: String) -> Bool {
        if kind == .file || kind == .folder {
            return ClipboardFile.from(items).contains { $0.name.range(of: query, options: .caseInsensitive) != nil }
        }
        let url = NSPasteboard.PasteboardType.URL.rawValue
        let string = NSPasteboard.PasteboardType.string.rawValue
        guard kind == .text || kind == .link else { return false }
        return items.contains { item in
            guard !Task.isCancelled else { return false }
            let text: String?
            let plain = item.first { $0.type == string && !$0.data.isEmpty }
            let address = item.first { $0.type == url && !$0.data.isEmpty }
            if let format = address ?? plain {
                let value = String(decoding: format.data, as: UTF8.self)
                text = value.contains(where: { !$0.isWhitespace }) ? value : richText(in: item)
            } else {
                text = richText(in: item)
            }
            return text?.range(of: query, options: .caseInsensitive) != nil
        }
    }

    // Derive a searchable string without rendering HTML or loading its resources.
    static func richText(in item: [ClipboardSnapshot.Representation], byteLimit: Int = .max) -> String? {
        for format in item where !format.data.isEmpty && format.data.count <= byteLimit {
            let type = NSPasteboard.PasteboardType(format.type)
            let text: String?
            switch type {
            case .rtf:
                text = NSAttributedString(rtf: format.data, documentAttributes: nil)?.string
            case .rtfd:
                text = NSAttributedString(rtfd: format.data, documentAttributes: nil)?.string
            default:
                guard let body = htmlBody(in: format) else { continue }
                var result = ""
                appendHTMLText(body, to: &result)
                text = result
            }
            if let text, !text.isEmpty { return text }
        }
        return nil
    }

    private static func htmlBody(in format: ClipboardSnapshot.Representation) -> XMLNode? {
        let type = NSPasteboard.PasteboardType(format.type)
        let data: Data
        var declaredEncoding: String.Encoding?
        if type == .html {
            data = format.data
        } else if ClipboardFormats.webArchives.contains(type) {
            let archive = (try? PropertyListSerialization.propertyList(from: format.data, format: nil)) as? [String: Any]
            let resource = archive?["WebMainResource"] as? [String: Any]
            guard let resourceData = resource?["WebResourceData"] as? Data else { return nil }
            data = resourceData
            if let name = resource?["WebResourceTextEncodingName"] as? String {
                let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
                if encoding != kCFStringEncodingInvalidId {
                    declaredEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
                }
            }
        } else {
            return nil
        }

        let options: XMLNode.Options = [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
        let decoded = declaredEncoding.flatMap { String(data: data, encoding: $0) }
            ?? String(data: data, encoding: .utf8)
        // The byte initializer can misread UTF-8 fragments, even with an HTML5 charset tag.
        var document: XMLDocument?
        if let decoded {
            var markup = decoded[...]
            if markup.first == "\u{FEFF}" { markup.removeFirst() }
            while markup.last == "\u{0}" { markup.removeLast() }
            // The original XML declaration refers to bytes that have already been decoded.
            if markup.hasPrefix("<?xml"), markup.dropFirst(5).first?.isWhitespace == true,
               let declarationEnd = markup.range(of: "?>") {
                markup = markup[declarationEnd.upperBound...]
            }
            if !markup.utf8.contains(0) {
                document = try? XMLDocument(xmlString: String(markup), options: options)
            }
        }
        guard let document = document ?? (try? XMLDocument(data: data, options: options)) else { return nil }
        return try? document.nodes(forXPath: "//*[local-name()='body']").first
    }

    @MainActor
    static func previewText(_ items: [[ClipboardSnapshot.Representation]]) -> NSAttributedString? {
        let result = NSMutableAttributedString()
        for item in items {
            var content: NSAttributedString?
            for format in item {
                switch NSPasteboard.PasteboardType(format.type) {
                case .rtfd: content = NSAttributedString(rtfd: format.data, documentAttributes: nil)
                case .rtf: content = NSAttributedString(rtf: format.data, documentAttributes: nil)
                default:
                    if let body = htmlBody(in: format) {
                        let rendered = NSMutableAttributedString()
                        appendPreview(body, to: rendered, attributes: [.font: NSFont.systemFont(ofSize: 15),
                                                                       .foregroundColor: Palette.text])
                        if rendered.length > 0 { content = rendered }
                    }
                }
                if content != nil { break }
            }
            if content == nil, let image = HistoryThumbnailLoader.previewBitmap(in: item) {
                content = imageAttachment(image)
            }
            if content == nil,
               let plain = item.first(where: { $0.type == NSPasteboard.PasteboardType.URL.rawValue })
                ?? item.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue }) {
                let value = String(decoding: plain.data, as: UTF8.self)
                if value.contains(where: { !$0.isWhitespace }) {
                    content = NSAttributedString(string: value,
                                                 attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: Palette.text])
                }
            }
            if content == nil, let plain = richText(in: item) {
                content = NSAttributedString(string: plain, attributes: [.foregroundColor: Palette.text])
            }
            guard let content else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(content)
        }
        return result.length > 0 ? result : nil
    }

    @MainActor
    private static func appendPreview(_ node: XMLNode, to output: NSMutableAttributedString,
                                      attributes: [NSAttributedString.Key: Any]) {
        if node.kind == .text {
            output.append(NSAttributedString(string: node.stringValue ?? "", attributes: attributes))
            return
        }
        guard let tag = node.localName?.lowercased(), node.kind == .element,
              !["script", "style", "template", "iframe", "object"].contains(tag) else { return }
        var style = attributes
        let element = node as? XMLElement
        let css: [String: String] = (element?.attribute(forName: "style")?.stringValue ?? "")
            .split(separator: ";").reduce(into: [:]) { properties, declaration in
                let pair = declaration.split(separator: ":", maxSplits: 1)
                if pair.count == 2 {
                    properties[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                        pair[1].trimmingCharacters(in: .whitespaces)
                }
            }
        let oldFont = (style[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 15)
        let heading = tag.count == 2 && tag.first == "h" && tag.last?.isNumber == true
        let size = css["font-size"].flatMap { Double($0.prefix { $0.isNumber || $0 == "." }) }.map { min(max(8, $0), 96) }
        let family = css["font-family"]?.split(separator: ",").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        var font = family.flatMap { NSFont(name: $0, size: size ?? oldFont.pointSize) }
            ?? NSFontManager.shared.convert(oldFont, toSize: size ?? (heading ? 22 : oldFont.pointSize))
        if heading || ["b", "strong"].contains(tag) || ["bold", "600", "700", "800", "900"].contains(css["font-weight"] ?? "") {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if ["i", "em"].contains(tag) || css["font-style"] == "italic" {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        style[.font] = font
        if let color = css["color"].flatMap(previewColor) { style[.foregroundColor] = color }
        if let align = css["text-align"], let alignment = ["left": NSTextAlignment.left, "center": .center,
                                                          "right": .right, "justify": .justified][align] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            style[.paragraphStyle] = paragraph
        }
        if tag == "a" || tag == "u" { style[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if tag == "a" { style[.foregroundColor] = Palette.accent }
        if tag == "img" {
            let source = element?.attribute(forName: "src")?.stringValue ?? ""
            if source.hasPrefix("data:image/"), let marker = source.range(of: ";base64,"),
               let data = Data(base64Encoded: String(source[marker.upperBound...]), options: .ignoreUnknownCharacters),
               let image = HistoryThumbnailLoader.previewBitmap(data) {
                output.append(imageAttachment(image))
            } else if let alternative = element?.attribute(forName: "alt")?.stringValue {
                output.append(NSAttributedString(string: alternative, attributes: style))
            }
        }
        if htmlBlockElements.contains(tag), output.length > 0, !output.string.hasSuffix("\n") {
            output.append(NSAttributedString(string: "\n", attributes: style))
        }
        for child in node.children ?? [] { appendPreview(child, to: output, attributes: style) }
        if htmlBlockElements.contains(tag), !output.string.hasSuffix("\n") {
            output.append(NSAttributedString(string: "\n", attributes: style))
        }
    }

    @MainActor
    private static func imageAttachment(_ bitmap: CGImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let width = min(CGFloat(bitmap.width), 540)
        let size = NSSize(width: width, height: width * CGFloat(bitmap.height) / CGFloat(bitmap.width))
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: NSImage(cgImage: bitmap, size: size))
        return NSAttributedString(attachment: attachment)
    }

    private static func previewColor(_ value: String) -> NSColor? {
        let components: [Double]
        if value.hasPrefix("#"), value.count == 7, let rgb = UInt32(value.dropFirst(), radix: 16) {
            components = [Double(rgb >> 16), Double((rgb >> 8) & 255), Double(rgb & 255)]
        } else if value.hasPrefix("rgb("), value.hasSuffix(")") {
            components = value.dropFirst(4).dropLast().split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        } else {
            return nil
        }
        guard components.count == 3, components.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return NSColor(srgbRed: components[0] / 255, green: components[1] / 255,
                       blue: components[2] / 255, alpha: 1)
    }

    private static func appendHTMLText(_ node: XMLNode, to result: inout String) {
        if node.kind == .text {
            result += node.stringValue ?? ""
            return
        }
        guard node.kind == .element, let name = node.localName?.lowercased(),
              name != "style", name != "script", name != "template" else { return }
        let separatesText = htmlBlockElements.contains(name)
        if separatesText { result += "\n" }
        for child in node.children ?? [] { appendHTMLText(child, to: &result) }
        if separatesText { result += "\n" }
    }

    static func search(_ query: String, records: [HistoryRecord], directory: URL) -> Set<UUID> {
        var matches = Set<UUID>()
        for record in records where record.kind != .image {
            if Task.isCancelled { break }
            let payload = HistoryStore.payload(record.id, in: directory)
            do {
                let data = try Data(contentsOf: payload, options: .mappedIfSafe)
                if Self.matches(try decode(data), kind: record.kind, query: query) { matches.insert(record.id) }
            } catch {
                HistoryLog.storage.error("Search payload unavailable: \((error as NSError).code)")
            }
        }
        return matches
    }

    private struct Reader {
        let data: Data
        var offset = 0
        var remaining: Int { data.count - offset }

        mutating func count() throws -> Int {
            guard remaining >= 8 else { throw Failure.invalid }
            let end = offset + 8
            let result = data.withUnsafeBytes { bytes in
                UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            }
            offset = end
            guard let count = Int(exactly: result) else { throw Failure.invalid }
            return count
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count <= remaining else { throw Failure.invalid }
            let end = offset + count
            defer { offset = end }
            return data[offset..<end]
        }
    }
}

actor HistoryThumbnailLoader {
    let directory: URL
    static let maximumPixels = 48

    init(directory: URL) { self.directory = directory }

    func image(for id: UUID) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            do {
                let payload = HistoryStore.payload(id, in: directory)
                let data = try Data(contentsOf: payload, options: .mappedIfSafe)
                let items = try HistoryPayload.decode(data)
                if let image = Self.image(in: items, maximumPixels: Self.maximumPixels) { return image }
                HistoryLog.storage.error("History image thumbnail could not be decoded")
            } catch {
                HistoryLog.storage.error("Thumbnail payload unavailable: \((error as NSError).code)")
            }
            return nil
        }
    }

    func previewImage(in items: [[ClipboardSnapshot.Representation]]) -> CGImage? {
        autoreleasepool { Self.image(in: items, maximumPixels: 1600) }
    }

    static func previewBitmap(in item: [ClipboardSnapshot.Representation]) -> CGImage? {
        image(in: [item], maximumPixels: 1200)
    }

    static func previewBitmap(_ data: Data) -> CGImage? {
        thumbnail(from: .init(type: NSPasteboard.PasteboardType.png.rawValue, data: data), maximumPixels: 1200)
    }

    private static func image(in items: [[ClipboardSnapshot.Representation]], maximumPixels: Int) -> CGImage? {
        for item in items {
            for format in item where ClipboardFormats.rasterImages.contains(format.type) {
                guard !Task.isCancelled else { return nil }
                if let image = Self.thumbnail(from: format, maximumPixels: maximumPixels) { return image }
            }
        }
        return nil
    }

    private static func thumbnail(from format: ClipboardSnapshot.Representation, maximumPixels: Int) -> CGImage? {
        let readOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(format.data as CFData, readOptions),
              let type = CGImageSourceGetType(source) as String?,
              ClipboardFormats.rasterImages.contains(type) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
