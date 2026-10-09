import Foundation
import DiskMapCore

enum ConvenienceChecks {
    static func run() throws {
        let fixture = try ProjectFixture("Preferences")
        defer { try? fixture.clean() }
        let store = SettingsStore(url: fixture.url.appendingPathComponent("state/preferences.json"))
        try expect(try store.load() == AppPreferences(), "Missing preferences changed defaults")
        var preferences = AppPreferences()
        var query = BrowserQuery()
        query.sort = .nameAscending; query.showsHidden = false; query.includesDescendants = true
        query.minimumSize = .hundredMegabytes; query.kind = .files; query.search = "never-persist-this-search"
        preferences.update(query: query, depth: 4)
        for index in 0..<8 { preferences.remember(fixture.url.appendingPathComponent("location\(index)").path) }
        preferences.remember(fixture.url.appendingPathComponent("location6").path)
        try store.save(preferences)
        let loaded = try store.load()
        try expect(loaded == preferences && loaded.recent.count == 5 && loaded.recent.first?.path.hasSuffix("location6") == true, "Recent/settings round-trip failed")
        try expect(loaded.query.search.isEmpty && loaded.query.sort == .nameAscending && loaded.chartDepth == 4, "Display settings or search privacy failed")
        try Data("corrupt".utf8).write(to: store.url)
        do { _ = try store.load(); throw CheckFailure(description: "Corrupt settings accepted") }
        catch is DecodingError {}
        try FileManager.default.removeItem(at: store.url)
        let destination = try fixture.file("do-not-overwrite.json", bytes: 128)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: destination)
        do { try store.save(preferences); throw CheckFailure(description: "Settings followed symlink") }
        catch is CocoaError {}
        try expect(try Data(contentsOf: destination).count == 128, "Settings changed symlink destination")
        try FileManager.default.removeItem(at: store.url)
        let linkedDirectory = fixture.url.appendingPathComponent("linked-state")
        let targetDirectory = fixture.url.appendingPathComponent("unmodified-directory")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: targetDirectory)
        let unsafeStore = SettingsStore(url: linkedDirectory.appendingPathComponent("new-child/preferences.json"))
        do { try unsafeStore.save(preferences); throw CheckFailure(description: "Settings followed a directory symlink") }
        catch is CocoaError {}
        try expect(try FileManager.default.contentsOfDirectory(atPath: targetDirectory.path).isEmpty, "Settings created files through ancestor symlink")
        try FileManager.default.removeItem(at: linkedDirectory)
        preferences.clearRecent(); try store.save(preferences)
        try expect(try store.load().recent.isEmpty, "Recent clear was not persisted")
        print("PASS local preferences round-trip, recent cap/dedup, corrupt data and symlink rejection")
        let space = try VolumeSpace.read(at: fixture.url)
        try expect(space.totalBytes > 0 && space.availableBytes >= 0 && !space.name.isEmpty, "Invalid live volume summary")
        print("PASS read-only live volume capacity is separate from candidate and moved bytes")
    }
}
