import CoreData
import Darwin

struct HistoryLimits: Sendable {
    var count = 300
    var bytes: Int64 = 1_000_000_000
    static let standard = Self()
}

struct HistoryRecord: Sendable, Identifiable {
    let id: UUID
    let fingerprint: String
    let copiedAt: Date
    let kind: HistoryEntry.Kind
    let summary: String
    let payloadBytes: Int64

    func entry(now: Date = .now) -> HistoryEntry {
        let minutes = max(0, Int(now.timeIntervalSince(copiedAt) / 60))
        let time = switch minutes {
        case 0: "刚刚"
        case 1..<60: "\(minutes) 分钟"
        case 60..<1440: "\(minutes / 60) 小时"
        default: copiedAt.formatted(.dateTime.month().day())
        }
        return HistoryEntry(kind: kind, title: summary, time: time, image: nil, id: id)
    }
}

struct HistoryContents: Sendable {
    var records: [HistoryRecord] = []
    var bytes: Int64 = 0
    var durabilityPending = false
}

enum HistoryStoreError: Error { case tooLarge, invalidIndex }

/// Only the serial history worker opens this store. The index is the commit point:
/// until the atomic rename succeeds, the old index and all of its payloads are intact.
final class HistoryStore {
    enum Checkpoint { case beforePublishingIndex }
    private let directory: URL
    private let limits: HistoryLimits
    private let model: NSManagedObjectModel
    private let lock: Int32
    private let check: (Checkpoint) throws -> Void
    private(set) var contents: HistoryContents

    func representations(for id: UUID) throws -> [[ClipboardSnapshot.Representation]] {
        guard let record = contents.records.first(where: { $0.id == id }) else {
            throw HistoryPayload.Failure.missingRepresentation
        }
        return try HistoryPayload.decode(checkedPayload(record))
    }

    private func checkedPayload(_ record: HistoryRecord) throws -> Data {
        let url = payload(record.id)
        guard try Self.fileSize(url) == record.payloadBytes else { throw HistoryPayload.Failure.invalid }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard ClipboardSnapshot.fingerprint(of: [data]) == record.fingerprint else {
            throw HistoryPayload.Failure.invalid
        }
        return data
    }

    private var index: URL { directory.appending(path: "History.sqlite") }
    private var candidate: URL { directory.appending(path: "Pending.sqlite") }

    init(directory: URL, limits: HistoryLimits, check: @escaping (Checkpoint) throws -> Void = { _ in }) throws {
        self.directory = directory
        self.limits = limits
        self.check = check
        model = Self.makeModel()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let lock = open(directory.appending(path: "Writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Self.posixError() }
        do {
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Self.posixError() }
            self.lock = lock
            contents = HistoryContents()
        } catch {
            close(lock)
            throw error
        }

        if try exists(index) {
            contents = try readIndex()
        }
        try syncDirectory()
        try removeUnreferencedFiles()
    }

    deinit { close(lock) }

    @discardableResult
    func save(_ snapshot: ClipboardSnapshot, copiedAt: Date = .now) throws -> HistoryContents {
        let chunks = snapshot.chunks
        let payloadBytes = chunks.reduce(Int64(0)) { $0 + Int64($1.count) }
        guard payloadBytes <= limits.bytes, limits.count > 0 else { throw HistoryStoreError.tooLarge }

        try syncDirectory()
        try removeUnreferencedFiles()
        let fingerprint = ClipboardSnapshot.fingerprint(of: chunks)
        let duplicate = contents.records.first { $0.fingerprint == fingerprint }
        var reusableID: UUID?
        if let duplicate {
            do {
                _ = try checkedPayload(duplicate)
                reusableID = duplicate.id
            } catch {
                HistoryLog.storage.error("Replacing unreadable duplicate payload: \((error as NSError).code)")
            }
        }
        let record = HistoryRecord(
            id: reusableID ?? UUID(), fingerprint: fingerprint, copiedAt: copiedAt,
            kind: snapshot.kind, summary: snapshot.summary, payloadBytes: payloadBytes
        )
        var records = [record] + contents.records.filter { $0.id != duplicate?.id }.prefix(limits.count - 1)
        var total = records.reduce(Int64(0)) { $0 + $1.payloadBytes }

        while records.count > 1 && total > limits.bytes {
            total -= records.removeLast().payloadBytes
        }

        // Measure the candidate's actual SQLite length, including the page overhead.
        // A rejected candidate never publishes a new index or evicts any existing record.
        defer { removePendingAfterFailure() }
        while true {
            try writeIndex(records)
            let bytes = try fileSize(candidate)
            if total + bytes <= limits.bytes {
                total += bytes
                break
            }
            guard records.count > 1 else { throw HistoryStoreError.tooLarge }
            total -= records.removeLast().payloadBytes
        }

        let newPayload = reusableID == nil ? payload(record.id) : nil
        var createdPayload: URL?
        do {
            if let newPayload {
                try writePayload(chunks, to: newPayload)
                createdPayload = newPayload
                try syncDirectory()
            }
            try check(.beforePublishingIndex)
            guard rename(candidate.path, index.path) == 0 else { throw Self.posixError() }
        } catch {
            if let createdPayload { removeFailedPayload(createdPayload) }
            throw error
        }
        contents = HistoryContents(records: records, bytes: total)
        // If unlink fails, preserve the committed index and retry cleanup before the next write.
        do {
            try syncDirectory()
        } catch {
            contents.durabilityPending = true
            HistoryLog.storage.error("History directory sync failed: \((error as NSError).code)")
            return contents
        }
        do { try removeUnreferencedFiles() }
        catch { HistoryLog.storage.error("History cleanup failed: \((error as NSError).code)") }
        return contents
    }

    private func readIndex() throws -> HistoryContents {
        let directory = self.directory
        let records = try withIndex(at: index, readOnly: true) { context in
            let fetch = NSFetchRequest<NSManagedObject>(entityName: "Record")
            fetch.sortDescriptors = [NSSortDescriptor(key: "position", ascending: true)]
            return try context.fetch(fetch).map { row -> HistoryRecord in
                guard let id = row.value(forKey: "id") as? UUID,
                      let fingerprint = row.value(forKey: "fingerprint") as? String,
                      let date = row.value(forKey: "copiedAt") as? Date,
                      let kind = (row.value(forKey: "kind") as? String).flatMap(HistoryEntry.Kind.init(rawValue:)),
                      let summary = row.value(forKey: "summary") as? String,
                      let number = row.value(forKey: "payloadBytes") as? NSNumber,
                      try Self.fileSize(Self.payload(id, in: directory)) == number.int64Value else { throw HistoryStoreError.invalidIndex }
                return HistoryRecord(id: id, fingerprint: fingerprint, copiedAt: date,
                                     kind: kind, summary: summary, payloadBytes: number.int64Value)
            }
        }
        let bytes = try fileSize(index) + records.reduce(Int64(0)) { $0 + $1.payloadBytes }
        return HistoryContents(records: records, bytes: bytes)
    }

    private func writeIndex(_ records: [HistoryRecord]) throws {
        if try exists(candidate) { try FileManager.default.removeItem(at: candidate) }
        try withIndex(at: candidate, readOnly: false) { context in
            for (position, record) in records.enumerated() {
                let row = NSEntityDescription.insertNewObject(forEntityName: "Record", into: context)
                row.setValue(position, forKey: "position")
                row.setValue(record.id, forKey: "id")
                row.setValue(record.fingerprint, forKey: "fingerprint")
                row.setValue(record.copiedAt, forKey: "copiedAt")
                row.setValue(record.kind.rawValue, forKey: "kind")
                row.setValue(record.summary, forKey: "summary")
                row.setValue(record.payloadBytes, forKey: "payloadBytes")
            }
            try context.save()
        }
        guard chmod(candidate.path, 0o600) == 0 else { throw Self.posixError() }
    }

    private func withIndex<T: Sendable>(
        at url: URL, readOnly: Bool, operation: @Sendable (NSManagedObjectContext) throws -> T
    ) throws -> T {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let index = try coordinator.addPersistentStore(
            type: .sqlite, at: url,
            options: [NSReadOnlyPersistentStoreOption: readOnly,
                      NSSQLitePragmasOption: ["journal_mode": "DELETE", "synchronous": "FULL"]]
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let result = Result { try context.performAndWait {
            defer { context.reset() }
            return try operation(context)
        } }
        try coordinator.remove(index)
        return try result.get()
    }

    private func writePayload(_ chunks: [Data], to url: URL) throws {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            for chunk in chunks { try file.write(contentsOf: chunk) }
            try file.synchronize()
            try file.close()
        } catch {
            do { try file.close() }
            catch { HistoryLog.storage.error("Payload close failed: \((error as NSError).code)") }
            removeFailedPayload(url)
            throw error
        }
    }

    private func removeFailedPayload(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { HistoryLog.storage.error("Uncommitted payload cleanup failed: \((error as NSError).code)") }
    }

    private func payload(_ id: UUID) -> URL {
        Self.payload(id, in: directory)
    }

    static func payload(_ id: UUID, in directory: URL) -> URL {
        directory.appending(path: id.uuidString + ".payload")
    }

    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw Self.posixError() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Self.posixError() }
    }

    private func removeUnreferencedFiles() throws {
        let retained = Set(contents.records.map(\.id))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "payload" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  file.lastPathComponent == payload(id).lastPathComponent, !retained.contains(id) else { continue }
            _ = try fileSize(file)
            try FileManager.default.removeItem(at: file)
        }
        if try exists(candidate) { try FileManager.default.removeItem(at: candidate) }
        let journal = directory.appending(path: "Pending.sqlite-journal")
        if try exists(journal) { try FileManager.default.removeItem(at: journal) }
    }

    private func removePendingAfterFailure() {
        if FileManager.default.fileExists(atPath: candidate.path) {
            do { try FileManager.default.removeItem(at: candidate) }
            catch { HistoryLog.storage.error("Temporary index cleanup failed: \((error as NSError).code)") }
        }
    }

    private func fileSize(_ url: URL) throws -> Int64 { try Self.fileSize(url) }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize else {
            throw HistoryStoreError.invalidIndex
        }
        return Int64(bytes)
    }

    private func exists(_ url: URL) throws -> Bool {
        do {
            _ = try fileSize(url)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            error.code == NSFileReadNoSuchFileError {
            return false
        }
    }

    private static func makeModel() -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = "Record"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let fields: [(String, NSAttributeType)] = [
            ("id", .UUIDAttributeType), ("position", .integer64AttributeType),
            ("fingerprint", .stringAttributeType), ("copiedAt", .dateAttributeType),
            ("kind", .stringAttributeType), ("summary", .stringAttributeType),
            ("payloadBytes", .integer64AttributeType)
        ]
        entity.properties = fields.map { name, type in
            let field = NSAttributeDescription()
            field.name = name
            field.attributeType = type
            return field
        }
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
