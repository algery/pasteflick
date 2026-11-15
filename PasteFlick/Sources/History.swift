import Foundation

struct HistoryEntry: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case text, link, image, file, folder

        var symbol: String {
            switch self {
            case .text: "text.alignleft"
            case .link: "link"
            case .image: "photo"
            case .file: "doc"
            case .folder: "folder"
            }
        }
    }

    let kind: Kind
    let title: String
    let time: String
    let image: String?
    let id: UUID?

    init(kind: Kind, title: String, time: String, image: String?, id: UUID? = nil) {
        self.kind = kind
        self.title = title
        self.time = time
        self.image = image
        self.id = id
    }
}

struct History {
    static let defaultRowCount = 12

    private(set) var entries: [HistoryEntry] = []
    private(set) var isOpen = false

    mutating func open(entries: [HistoryEntry]) {
        guard !isOpen else { return }
        self.entries = entries
        isOpen = true
    }

    mutating func refresh(entries: [HistoryEntry]) {
        guard isOpen else { return }
        self.entries = entries
    }

    mutating func close() {
        entries = []
        isOpen = false
    }
}
