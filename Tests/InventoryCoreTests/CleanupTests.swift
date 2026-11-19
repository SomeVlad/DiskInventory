import Foundation
import Testing
@testable import InventoryCore

private func makeFile(_ url: URL, bytes: Int = 16_384, age days: Double? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
    if let days {
        let date = Date(timeIntervalSinceNow: -days * 86_400)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }
}

private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appending(path: "cleanup-" + UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home.resolvingSymlinksInPath()
}

@Test func cleanupFindsRegenerableAndSafeItems() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try makeFile(home.appending(path: "Library/Caches/com.example.app/blob"))
    try makeFile(home.appending(path: "Library/Application Support/Tool/package.json"))
    try makeFile(home.appending(path: "Library/Application Support/Tool/node_modules/dep/index.js"))
    try makeFile(home.appending(path: "Dev/web/package.json"))
    try makeFile(home.appending(path: "Dev/web/node_modules/dep/index.js"))
    try makeFile(home.appending(path: "Dev/web/node_modules/dep/node_modules/inner/index.js"))
    try makeFile(home.appending(path: "Dev/loose/node_modules/dep/index.js"))
    try makeFile(home.appending(path: "Dev/crate/Cargo.toml"))
    try makeFile(home.appending(path: "Dev/crate/target/debug/app"))
    try makeFile(home.appending(path: ".vscode/extensions/ext/package.json"))
    try makeFile(home.appending(path: ".vscode/extensions/ext/node_modules/dep/index.js"))
    try makeFile(home.appending(path: "Downloads/Installer.dmg"))
    try makeFile(home.appending(path: "Downloads/notes.txt"))

    let snapshot = try InventoryScanner.scan(home)
    let groups = CleanupAnalyzer.analyze(snapshot, home: home)
    let found = Dictionary(uniqueKeysWithValues: groups.map { group in
        (group.category.id, Set(group.items.map { snapshot.url(for: $0.node).path.replacingOccurrences(of: home.path + "/", with: "") }))
    })

    #expect(found["caches"] == ["Library/Caches/com.example.app"])
    #expect(found["build-artifacts"] == ["Dev/web/node_modules", "Dev/crate/target"])
    #expect(found["installers"] == ["Downloads/Installer.dmg"])
    #expect(groups.first?.category.safety == .safe)
    let project = try InventoryScanner.scan(home.appending(path: "Dev"))
    let inside = CleanupAnalyzer.analyze(project, home: home).flatMap(\.items).map { project.url(for: $0.node).lastPathComponent }
    #expect(Set(inside) == ["node_modules", "target"])
    let artifacts = try #require(groups.first { $0.category.id == "build-artifacts" })
    let web = try #require(snapshot.find(home.appending(path: "Dev/web/node_modules")))
    #expect(artifacts.items.first { $0.node == web }?.size == snapshot.nodes[web].allocated)
}

@Test func staleFilesUseTheLatestKnownActivity() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try makeFile(home.appending(path: "Movies/old.mov"), bytes: 65_536, age: 400)
    try makeFile(home.appending(path: "Movies/recent.mov"), bytes: 65_536, age: 3)
    try makeFile(home.appending(path: "Movies/tiny-old.mov"), bytes: 4_096, age: 400)
    try makeFile(home.appending(path: "Pictures/Library.photoslibrary/database.db"), bytes: 65_536, age: 400)
    try makeFile(home.appending(path: "Dev/old-build.bin"), bytes: 65_536, age: 400)

    let snapshot = try InventoryScanner.scan(home)
    let stale = CloudOffload.staleFiles(in: snapshot, minSize: 32_768, olderThanDays: 180, home: home)
    #expect(stale.map { URL(filePath: $0.path).lastPathComponent } == ["old.mov"])
    #expect(try #require(stale.first?.lastActivity) < Date(timeIntervalSinceNow: -300 * 86_400))
}

@Test func cloudDestinationsAndMoves() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    let drive = home.appending(path: "Library/CloudStorage/GoogleDrive-me@example.com/My Drive", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: iCloud, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)

    let destinations = CloudOffload.destinations(home: home)
    #expect(destinations.map(\.service) == [.iCloudDrive, .googleDrive])
    #expect(destinations.last?.title == "Google Drive (me@example.com)")
    #expect(destinations.last?.root.path == drive.path)

    let file = home.appending(path: "Movies/Trip/clip.mov")
    try makeFile(file)
    let googleDrive = try #require(destinations.last)
    let expected = drive.appending(path: "Архив с Mac/Movies/Trip/clip.mov")
    #expect(CloudOffload.target(for: file, in: googleDrive, home: home).path == expected.path)
    let moved = try CloudOffload.move(file, to: googleDrive, home: home)
    #expect(moved.path == expected.path)
    #expect(FileManager.default.fileExists(atPath: expected.path))
    #expect(!FileManager.default.fileExists(atPath: file.path))

    try makeFile(file)
    let second = try CloudOffload.move(file, to: googleDrive, home: home)
    #expect(second.lastPathComponent == "clip 2.mov")
}
