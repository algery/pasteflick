import AppKit
import os

@MainActor
struct AppEnvironment {
    let makePasteboard: () -> NSPasteboard
    let dataDirectory: URL
    let entries: [HistoryEntry]
    let showsSamples: Bool
    let ownsPasteboard: Bool
    var showsPermissionGuide: Bool { !ownsPasteboard }

    private static let testBundleIdentifier = "local.shuntie.test.debug"

    static func live(arguments: [String], bundle: Bundle = .main) throws -> Self {
        #if DEBUG
        let samples = arguments.contains("--samples")
        if samples || bundle.bundleIdentifier == testBundleIdentifier {
            var entries: [HistoryEntry] = []
            if samples {
                let sampleFile = bundle.url(forResource: "HistorySamples", withExtension: "json")
                guard let sampleFile else { throw CocoaError(.fileNoSuchFile) }
                entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: sampleFile))
            }
            if !samples,
               let fixtureID = ProcessInfo.processInfo.environment["SHUNTIE_TEST_FIXTURE"].flatMap(UUID.init(uuidString:)) {
                let path = Self.testFixture(fixtureID)
                return isolated(at: path, name: testPasteboardName(fixtureID))
            }
            let scratch = FileManager.default.temporaryDirectory
                .appending(path: "Shuntie-\(UUID().uuidString)", directoryHint: .isDirectory)
            return isolated(at: scratch, entries: entries, showsSamples: samples)
        }
        #endif

        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        let folder = bundle.bundleIdentifier?.hasSuffix(".debug") == true ? "Shuntie-Dev" : "Shuntie"
        return Self(
            makePasteboard: { .general },
            dataDirectory: support.appending(path: folder, directoryHint: .isDirectory),
            entries: [],
            showsSamples: false,
            ownsPasteboard: false
        )
    }

    #if DEBUG
    static func testFixture(_ id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Shuntie-Test-\(id.uuidString)", directoryHint: .isDirectory)
    }

    static func testPasteboardName(_ id: UUID) -> NSPasteboard.Name {
        .init("local.shuntie.test.\(id.uuidString)")
    }
    #endif

    static func isolated(
        at directory: URL, entries: [HistoryEntry] = [], showsSamples: Bool = false,
        name: NSPasteboard.Name = .init("local.shuntie.test.\(UUID().uuidString)")
    ) -> Self {
        Self(
            makePasteboard: { NSPasteboard(name: name) },
            dataDirectory: directory,
            entries: entries,
            showsSamples: showsSamples,
            ownsPasteboard: true
        )
    }
}

@MainActor
enum Measurements {
    private static let signposter = OSSignposter(subsystem: "local.shuntie", category: "History")

    static func interval(_ name: StaticString, operation: () -> Void) {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        operation()
    }
}
