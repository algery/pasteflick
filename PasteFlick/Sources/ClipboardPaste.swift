import AppKit
import Darwin

struct ClipboardFile: Sendable {
    static let type = NSPasteboard.PasteboardType.fileURL.rawValue
    let url: URL
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }

    init?(_ data: Data) {
        guard let string = String(data: data, encoding: .utf8),
              let url = URL(string: string), url.isFileURL, url.baseURL == nil,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { return nil }
        self.url = url
    }

    static func from(_ items: [[ClipboardSnapshot.Representation]]) -> [Self] {
        items.compactMap { item in
            item.first { $0.type == type }.flatMap { Self($0.data) }
        }
    }

    var isLocallyAvailable: Bool {
        // Metadata probes do not need to open the file or enumerate directories.
        // Suppress File Provider materialization during this synchronous check.
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard previous >= 0,
              setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                             IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return false }
        defer {
            if setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) != 0 {
                HistoryLog.capture.error("Could not restore local file probe policy: \(errno)")
            }
        }
        let pathParts = url.path.split(separator: "/")
        guard !pathParts.contains("..") else { return false }
        var pathName = "/" + pathParts.filter { $0 != "." }.joined(separator: "/")
        for alias in ["/var", "/tmp", "/etc"] where pathName == alias || pathName.hasPrefix(alias + "/") {
            pathName = "/private" + pathName
            break
        }
        guard Self.isLocalMount(pathName) else { return false }
        return pathName.withCString { path in
            var metadata = stat()
            guard fstatat(AT_FDCWD, path, &metadata, AT_SYMLINK_NOFOLLOW_ANY) == 0,
                  metadata.st_flags & UInt32(SF_DATALESS) == 0 else { return false }
            let type = metadata.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG,
                  access(path, type == S_IFDIR ? R_OK | X_OK : R_OK) == 0 else { return false }
            var volume = statfs()
            return statfs(path, &volume) == 0 && volume.f_flags & UInt32(MNT_LOCAL) != 0
        }
    }

    private static func isLocalMount(_ path: String) -> Bool {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return false }
        let blank = statfs()
        var mounts = Array(repeating: blank, count: Int(count) + 8)
        let bytes = Int32(mounts.count * MemoryLayout.stride(ofValue: blank))
        let found = mounts.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, bytes, MNT_NOWAIT) }
        guard found > 0, Int(found) < mounts.count else { return false }
        var nearest: (length: Int, local: Bool)?
        for var mount in mounts.prefix(Int(found)) {
            let name = withUnsafeBytes(of: &mount.f_mntonname) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if (name == "/" || path == name || path.hasPrefix(name + "/")),
               name.count > (nearest?.length ?? 0) {
                nearest = (name.count, mount.f_flags & UInt32(MNT_LOCAL) != 0)
            }
        }
        return nearest?.local == true
    }
}

@MainActor
enum ClipboardPaste {
    enum Result: Equatable {
        case dispatched, permissionRequired, targetUnavailable, commandUnavailable, clipboardChanged
    }

    static func replace(
        _ items: [[ClipboardSnapshot.Representation]],
        expectedVersion: Int,
        prepare: () -> Int,
        write: ([NSPasteboardItem]) -> Bool,
        version: () -> Int,
        ignore: (Int) -> Void,
        unavailableFiles: (Int) -> Void = { _ in }
    ) -> Int? {
        guard !items.isEmpty else { return nil }
        var prepared: [NSPasteboardItem] = []
        for item in items {
            guard !item.isEmpty else { return nil }
            let output = NSPasteboardItem()
            for format in item {
                guard output.setData(format.data, forType: .init(format.type)) else { return nil }
            }
            prepared.append(output)
        }

        let fileItems = items.flatMap { $0.filter { $0.type == ClipboardFile.type } }
        let missingCount = fileItems.count { ClipboardFile($0.data)?.isLocallyAvailable != true }
        if missingCount > 0 {
            unavailableFiles(missingCount)
            return nil
        }
        guard version() == expectedVersion else { return nil }
        let started = prepare()
        guard version() == started, write(prepared) else { return nil }
        // writeObjects normally keeps the changeCount assigned by prepare. A newer
        // version here may belong to another app and must not be ignored or pasted.
        guard version() == started else { return nil }
        ignore(started)
        return started
    }
}
