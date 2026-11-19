import AppKit
import Darwin
import Foundation
import InventoryCore

let args = CommandLine.arguments
if args.count >= 3, ["--scan", "--fts", "--baseline"].contains(args[1]) {
    let start = ContinuousClock.now
    let root = URL(filePath: args[2], directoryHint: .isDirectory)
    do {
        if args[1] == "--baseline" {
            let (count, total) = try FoundationBaseline.run(root: root)
            print("\(count) entries, \(total) logical bytes, \(start.duration(to: .now)), \(peakRSS()) peak RSS bytes")
        } else {
            let snapshot = try InventoryScanner.scan(root, ignoreCreatorCode: !args.dropFirst(3).contains("--finder-kinds"), preferBulk: args[1] != "--fts")
            let seconds = start.duration(to: .now)
            let data = snapshot.nodes[0]
            print("\(snapshot.nodes.count) entries, \(data.logical) logical bytes, \(data.allocated) allocated bytes, \(snapshot.issueCount) skipped, \(snapshot.traversal.rawValue), \(seconds), \(peakRSS()) peak RSS bytes")
        }
    } catch {
        print(error.localizedDescription)
        exit(EXIT_FAILURE)
    }
} else {
    let app = NSApplication.shared
    let delegate = ApplicationController()
    delegate.testTrash = args.dropFirst().first == "--trash-smoke-test"
    if args.count >= 4, args[1] == "--screenshots" {
        delegate.screenshots = (URL(filePath: args[2], directoryHint: .isDirectory), URL(filePath: args[3], directoryHint: .isDirectory))
    }
    if args.count >= 3, ["--smoke-test", "--settings-smoke-test", "--layout-smoke-test"].contains(args[1]) {
        delegate.testLocation = URL(filePath: args[2], directoryHint: .isDirectory)
        if args[1] == "--layout-smoke-test" {
            delegate.testLayout = true
            Settings.layoutNamespace = "LayoutCheck." + UUID().uuidString
        }
        if args[1] == "--settings-smoke-test" {
            let domain = "local.diskinventory.appearance-test." + UUID().uuidString
            guard let store = UserDefaults(suiteName: domain) else { exit(EXIT_FAILURE) }
            Settings.store = store
            delegate.testSettingsDomain = domain
        }
    }
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

enum FoundationBaseline {
    static func run(root: URL) throws -> (Int, Int64) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .fileAllocatedSizeKey]
        guard let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            throw CocoaError(.fileReadUnknown)
        }
        var entries = 1
        var size: Int64 = 0
        while let item = paths.nextObject() as? URL {
            autoreleasepool {
                entries += 1
                if let attributes = try? item.resourceValues(forKeys: keys), attributes.isDirectory != true {
                    size += Int64(attributes.fileSize ?? 0)
                }
            }
        }
        return (entries, size)
    }
}

func peakRSS() -> Int {
    var usage = rusage()
    return getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : 0
}
