import AppKit
import CryptoKit
import UniformTypeIdentifiers

struct ClipboardSnapshot: Sendable {
    struct Representation: Sendable {
        let type: String
        let data: Data
    }

    let items: [[Representation]]
    let kind: HistoryEntry.Kind
    let summary: String

    // The payload and fingerprint use the same length-prefixed byte stream.
    var chunks: [Data] {
        var result = [Self.length(items.count)]
        for item in items {
            result.append(Self.length(item.count))
            for format in item {
                let type = Data(format.type.utf8)
                result.append(contentsOf: [Self.length(type.count), type, Self.length(format.data.count), format.data])
            }
        }
        return result
    }

    private static func length(_ count: Int) -> Data {
        var length = UInt64(count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) }
    }

    static func fingerprint(of chunks: [Data]) -> String {
        var hash = SHA256()
        for chunk in chunks { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ClipboardItem {
    let types: [NSPasteboard.PasteboardType]
    let data: (NSPasteboard.PasteboardType) -> Data?
}

struct ClipboardSource {
    let version: () -> Int
    let access: () -> ClipboardAccess
    let types: () -> [NSPasteboard.PasteboardType]?
    let items: () -> [ClipboardItem]?

    init(board: NSPasteboard) {
        version = { board.changeCount }
        access = {
            if #available(macOS 15.4, *), board.name == .general {
                switch board.accessBehavior {
                case .alwaysDeny: return .denied
                case .ask: return .ask
                default: break
                }
            }
            return .available
        }
        types = { board.types }
        items = {
            board.pasteboardItems?.map { item in
                ClipboardItem(types: item.types, data: { item.data(forType: $0) })
            }
        }
    }

    init(version: @escaping () -> Int, access: @escaping () -> ClipboardAccess,
         types: @escaping () -> [NSPasteboard.PasteboardType]?, items: @escaping () -> [ClipboardItem]?) {
        self.version = version
        self.access = access
        self.types = types
        self.items = items
    }
}

enum ClipboardAccess { case available, ask, denied }

enum ClipboardFormats {
    typealias PasteType = NSPasteboard.PasteboardType

    static let webArchives: Set<PasteType> = [.init("com.apple.webarchive"), .init("Apple Web Archive pasteboard type")]
    static let richText: Set<PasteType> = webArchives.union([.rtf, .rtfd, .html])
    static let rasterImages: Set<String> = [
        .png, .tiff, .jpeg, .gif, .heic, .heif, .webP, .bmp, .ico
    ].reduce(into: Set<String>()) { (types: inout Set<String>, type: UTType) in
        types.insert(type.identifier)
    }

    // Companion formats used for web selections, links and native rich text.
    private static let webKitSmartPaste = "dyn.ah62d4rv4gu8y63n2nuuhg5pbsm4ca6dbsr4gnkduqf31k3pcr7u1e3basv61a3k"
    private static let webKitURLsWithTitles = "dyn.ah62d4rv4gu8zs3pcnzme2641rf4guzdmsv0gn64uqm10c6xenv61a3k"
    private static let companion: Set<PasteType> = [
        .pdf, .tabularText, .multipleTextSelection, .init("public.url-name"),
        .init("org.chromium.source-url"), .init("org.chromium.web-custom-data"),
        .init(webKitSmartPaste), .init("NeXT smart paste pasteboard type"),
        .init(webKitURLsWithTitles), .init("WebURLsWithTitlesPboardType")
    ]

    static func isPrimary(_ type: PasteType) -> Bool {
        isBasicText(type) || isRichOrImage(type)
    }

    static func isBasicText(_ type: PasteType) -> Bool {
        type == .string || type == .URL
    }

    static func isRichOrImage(_ type: PasteType) -> Bool {
        richText.contains(type) || rasterImages.contains(type.rawValue)
    }

    static func supports(_ type: PasteType) -> Bool {
        isPrimary(type) || companion.contains(type)
    }
}

struct ClipboardCapture {
    enum Outcome {
        case ignored, superseded, tooLarge, readFailed, denied
        case snapshot(ClipboardSnapshot)
    }

    static let concealed: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"), .init("com.agilebits.onepassword")
    ]

    static func read(_ source: ClipboardSource, version: Int, byteLimit: Int64) -> Outcome {
        let outcome = readContents(source, byteLimit: byteLimit)
        if source.access() == .denied { return .denied }
        return source.version() == version ? outcome : .superseded
    }

    private static func readContents(_ source: ClipboardSource, byteLimit: Int64) -> Outcome {
        guard let types = source.types() else { return .readFailed }
        if types.isEmpty || !concealed.isDisjoint(with: types) { return .ignored }
        guard let items = source.items() else { return .readFailed }
        if items.contains(where: { !concealed.isDisjoint(with: $0.types) }) {
            return .ignored
        }
        if types.contains(.fileURL) || items.contains(where: { $0.types.contains(.fileURL) }) {
            return readFiles(items, byteLimit: byteLimit)
        }

        var byteCount: Int64 = 8
        var captured: [[ClipboardSnapshot.Representation]] = []
        var titles: [String] = []
        var kinds: [HistoryEntry.Kind] = []

        for item in items where item.types.contains(where: ClipboardFormats.isPrimary) {
            var formats: [ClipboardSnapshot.Representation] = []
            byteCount += 8
            for type in item.types where ClipboardFormats.supports(type) {
                guard let data = item.data(type), !data.isEmpty || !ClipboardFormats.isRichOrImage(type)
                else { return .readFailed }
                byteCount += 16 + Int64(type.rawValue.utf8.count) + Int64(data.count)
                if byteCount > byteLimit { return .tooLarge }
                formats.append(.init(type: type.rawValue, data: data))
            }
            // Match the existing layout for ordinary links and text so their
            // fingerprints still agree with copies written by older versions.
            if formats.allSatisfy({ ClipboardFormats.isBasicText(.init($0.type)) }) {
                formats.sort { $0.type < $1.type }
            }
            captured.append(formats)

            let url = formats.first { $0.type == NSPasteboard.PasteboardType.URL.rawValue }
                .map { visiblePrefix($0.data) } ?? ""
            if URL(string: url)?.isFileURL == true { return .ignored }
            let plain = formats.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }
            let body = plain.map { visiblePrefix($0.data).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let rich = formats.contains { ClipboardFormats.richText.contains(.init($0.type)) }
            let hasImage = formats.contains { ClipboardFormats.rasterImages.contains($0.type) }
            if rich {
                let text = body.isEmpty ? HistoryPayload.richText(in: formats, byteLimit: 512 * 1024) : body
                let oneLine = (text ?? "").split { $0.isWhitespace || $0 == "\u{fffc}" }.joined(separator: " ")
                if oneLine.isEmpty && hasImage {
                    titles.append("图片")
                    kinds.append(.image)
                } else {
                    titles.append(oneLine.isEmpty ? "富文本" : String(oneLine.prefix(240)))
                    kinds.append(.text)
                }
            } else if hasImage {
                titles.append("图片")
                kinds.append(.image)
            } else {
                let text = (url.isEmpty ? body : url).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
                titles.append(String(oneLine.prefix(240)))
                let isLink = !url.isEmpty || ((plain?.data.count ?? 0) <= 4096 && isWebAddress(body))
                kinds.append(isLink ? .link : .text)
            }
        }

        guard let firstKind = kinds.first else { return .ignored }
        let kind = kinds.allSatisfy { $0 == firstKind } ? firstKind : .text
        let summary = kind == .image && titles.count > 1 ? "\(titles.count) 张图片" : titles.joined(separator: " · ")
        return .snapshot(.init(items: captured, kind: kind, summary: String(summary.prefix(240))))
    }

    private static func readFiles(_ items: [ClipboardItem], byteLimit: Int64) -> Outcome {
        var captured: [[ClipboardSnapshot.Representation]] = []
        var first: ClipboardFile?
        let type = ClipboardFile.type
        var bytes: Int64 = 8
        for item in items {
            guard item.types.contains(.fileURL), let data = item.data(.fileURL),
                  let file = ClipboardFile(data) else { return .readFailed }
            bytes += 24 + Int64(type.utf8.count) + Int64(data.count)
            guard bytes <= byteLimit else { return .tooLarge }
            captured.append([.init(type: type, data: data)])
            if first == nil { first = file }
        }
        guard let first else { return .readFailed }
        let summary = captured.count == 1 ? first.name : "\(first.name) 等 \(captured.count) 项"
        let kind: HistoryEntry.Kind = captured.count == 1 && first.url.hasDirectoryPath ? .folder : .file
        return .snapshot(.init(items: captured, kind: kind, summary: String(summary.prefix(240))))
    }

    private static func visiblePrefix(_ data: Data) -> String {
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
        if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || data.count <= 4096 {
            return prefix
        }
        // The quick prefix may only contain whitespace. Find the first visible scalar
        // from byte zero using the string's UTF-8 representation without copying a suffix.
        let text = String(decoding: data, as: UTF8.self)
        guard let first = text.unicodeScalars.firstIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        return String(decoding: text.utf8[first...].prefix(4096), as: UTF8.self)
    }

    private static func isWebAddress(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace),
              let url = URLComponents(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host?.isEmpty == false
    }
}
