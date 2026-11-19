import CoreServices
import Darwin
import Foundation

public enum CleanupSafety: String, CaseIterable, Sendable {
    case safe, regenerable, review

    public var title: String {
        switch self {
        case .safe: "Можно удалять"
        case .regenerable: "Восстановится заново"
        case .review: "Стоит посмотреть"
        }
    }
}

public struct CleanupCategory: Hashable, Sendable {
    public let id: String
    public let title: String
    public let explanation: String
    public let safety: CleanupSafety
}

public struct CleanupItem: Sendable {
    public let node: Int
    public let category: CleanupCategory
    public let size: Int64
}

public struct CleanupGroup: Sendable {
    public let category: CleanupCategory
    public let items: [CleanupItem]

    public var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

public enum CleanupCategories {
    public static let trash = CleanupCategory(
        id: "trash", title: "Корзина",
        explanation: "Файлы уже выброшены; место вернётся только после очистки Корзины.", safety: .safe)
    public static let caches = CleanupCategory(
        id: "caches", title: "Кэши программ",
        explanation: "Программы пересоздают кэш сами; первый запуск после удаления может быть медленнее.", safety: .safe)
    public static let logs = CleanupCategory(
        id: "logs", title: "Журналы программ",
        explanation: "Нужны только для разбора сбоев; программы заводят новые.", safety: .safe)
    public static let simulatorCaches = CleanupCategory(
        id: "simulator-caches", title: "Кэши симуляторов Xcode",
        explanation: "Xcode пересобирает их при следующем запуске симулятора.", safety: .safe)
    public static let derivedData = CleanupCategory(
        id: "derived-data", title: "DerivedData Xcode",
        explanation: "Промежуточные файлы сборки; Xcode соберёт проект заново, это займёт время.", safety: .regenerable)
    public static let deviceSupport = CleanupCategory(
        id: "device-support", title: "Символы устройств iOS",
        explanation: "Xcode скопирует их снова при подключении устройства с этой версией iOS.", safety: .regenerable)
    public static let toolCaches = CleanupCategory(
        id: "tool-caches", title: "Кэши пакетных менеджеров",
        explanation: "npm, pip, Gradle, Cargo и другие скачают пакеты заново при следующей сборке.", safety: .regenerable)
    public static let buildArtifacts = CleanupCategory(
        id: "build-artifacts", title: "Артефакты сборки проектов",
        explanation: "node_modules, .build, target и подобное восстанавливаются командой установки или сборки проекта.", safety: .regenerable)
    public static let models = CleanupCategory(
        id: "models", title: "Локальные модели ИИ",
        explanation: "Скачиваются заново, но это десятки гигабайт трафика; удаляйте те, которыми не пользуетесь.", safety: .review)
    public static let installers = CleanupCategory(
        id: "installers", title: "Установщики и образы дисков",
        explanation: "Обычно программа уже установлена, а установщик можно скачать снова.", safety: .review)
    public static let archives = CleanupCategory(
        id: "xcode-archives", title: "Архивы Xcode",
        explanation: "Нужны, чтобы расшифровывать отчёты о сбоях выпущенных сборок; старые можно убрать.", safety: .review)
    public static let simulators = CleanupCategory(
        id: "simulators", title: "Устройства симулятора",
        explanation: "Данные установленных в симуляторы приложений; неиспользуемые лучше удалять через Xcode.", safety: .review)
    public static let deviceBackups = CleanupCategory(
        id: "device-backups", title: "Резервные копии iPhone и iPad",
        explanation: "Удаляйте только копии устройств, которых больше нет или которые есть в iCloud.", safety: .review)
}

public enum CleanupAnalyzer {
    private enum Pick { case itself, children }

    private struct PathRule {
        let path: String
        let pick: Pick
        let category: CleanupCategory
    }

    private struct NameRule {
        let name: String
        let siblings: [String]
        let inside: [String]
        let category: CleanupCategory
    }

    private static let pathRules: [PathRule] = [
        PathRule(path: ".Trash", pick: .itself, category: CleanupCategories.trash),
        PathRule(path: "Library/Caches", pick: .children, category: CleanupCategories.caches),
        PathRule(path: "Library/Logs", pick: .children, category: CleanupCategories.logs),
        PathRule(path: "Library/Developer/CoreSimulator/Caches", pick: .itself, category: CleanupCategories.simulatorCaches),
        PathRule(path: "Library/Developer/Xcode/DerivedData", pick: .children, category: CleanupCategories.derivedData),
        PathRule(path: "Library/Developer/Xcode/iOS DeviceSupport", pick: .children, category: CleanupCategories.deviceSupport),
        PathRule(path: "Library/Developer/Xcode/watchOS DeviceSupport", pick: .children, category: CleanupCategories.deviceSupport),
        PathRule(path: "Library/Developer/Xcode/Archives", pick: .children, category: CleanupCategories.archives),
        PathRule(path: "Library/Developer/CoreSimulator/Devices", pick: .children, category: CleanupCategories.simulators),
        PathRule(path: "Library/Application Support/MobileSync/Backup", pick: .children, category: CleanupCategories.deviceBackups),
        PathRule(path: ".npm/_cacache", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".cache", pick: .children, category: CleanupCategories.toolCaches),
        PathRule(path: ".gradle/caches", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".m2/repository", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".cargo/registry", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: "go/pkg/mod", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".pub-cache", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".bun/install/cache", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: "Library/pnpm/store", pick: .itself, category: CleanupCategories.toolCaches),
        PathRule(path: ".ollama/models", pick: .itself, category: CleanupCategories.models),
        PathRule(path: ".lmstudio/models", pick: .itself, category: CleanupCategories.models),
    ]

    private static let modelCaches: Set<String> = ["huggingface", "lm-studio", "torch", "whisper"]

    private static let nameRules: [NameRule] = [
        NameRule(name: "node_modules", siblings: ["package.json"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".build", siblings: ["Package.swift"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: "target", siblings: ["Cargo.toml"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: "Pods", siblings: ["Podfile"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: "DerivedData", siblings: [], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".gradle", siblings: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".next", siblings: ["package.json"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".turbo", siblings: ["package.json"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".parcel-cache", siblings: ["package.json"], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: "__pycache__", siblings: [], inside: [], category: CleanupCategories.buildArtifacts),
        NameRule(name: ".venv", siblings: [], inside: ["pyvenv.cfg"], category: CleanupCategories.buildArtifacts),
        NameRule(name: "venv", siblings: [], inside: ["pyvenv.cfg"], category: CleanupCategories.buildArtifacts),
    ]

    private static let installerSuffixes: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]

    public static func analyze(_ snapshot: ScanSummary, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CleanupGroup] {
        let size: (Int) -> Int64 = { snapshot.nodes[$0].allocated }
        var claimed = Set<Int>()
        var items: [CleanupItem] = []

        func claim(_ id: Int, _ category: CleanupCategory) {
            guard size(id) > 0, claimed.insert(id).inserted else { return }
            items.append(CleanupItem(node: id, category: category, size: size(id)))
        }

        let homePath = home.standardizedFileURL.path
        for rule in pathRules {
            guard let id = snapshot.locate(homePath + "/" + rule.path), snapshot.nodes[id].isDirectory else { continue }
            switch rule.pick {
            case .itself:
                claim(id, rule.category)
            case .children:
                for child in snapshot.children(of: id) where !snapshot.nodes[child].name.hasPrefix(".") {
                    let category = rule.path == ".cache" && modelCaches.contains(snapshot.nodes[child].name)
                        ? CleanupCategories.models : rule.category
                    claim(child, category)
                }
            }
        }

        let rulesByName = Dictionary(grouping: nameRules, by: \.name)

        func expandable(_ id: Int) -> Bool {
            let node = snapshot.nodes[id]
            return node.isDirectory && !claimed.contains(id) && !snapshot.kinds[Int(node.kind)].isPackage
        }

        var stack: [Int]
        if let homeID = snapshot.locate(homePath) {
            let library = snapshot.locate(homePath + "/Library")
            stack = snapshot.children(of: homeID).filter { id in
                id != library && !snapshot.nodes[id].name.hasPrefix(".") && expandable(id)
            }
        } else {
            let rootPath = snapshot.displayPath(of: 0)
            guard rootPath.hasPrefix(homePath + "/") else { return group(items) }
            let top = rootPath.dropFirst(homePath.count + 1).split(separator: "/").first.map(String.init) ?? ""
            guard top != "Library", !top.hasPrefix(".") else { return group(items) }
            stack = expandable(0) ? [0] : []
        }
        while let id = stack.popLast() {
            let children = snapshot.children(of: id)
            var names: Set<String>?
            for child in children where expandable(child) {
                if let rules = rulesByName[snapshot.nodes[child].name] {
                    let siblings = names ?? Set(children.map { snapshot.nodes[$0].name })
                    names = siblings
                    let rule = rules.first { rule in
                        (rule.siblings.isEmpty || !siblings.isDisjoint(with: rule.siblings))
                            && (rule.inside.isEmpty || !Set(snapshot.children(of: child).map { snapshot.nodes[$0].name }).isDisjoint(with: rule.inside))
                    }
                    if let rule {
                        claim(child, rule.category)
                        continue
                    }
                }
                stack.append(child)
            }
        }

        for folder in ["Downloads", "Desktop"] {
            guard let folderID = snapshot.locate(homePath + "/" + folder) else { continue }
            var pending = [folderID]
            while let id = pending.popLast() {
                for child in snapshot.children(of: id) {
                    let node = snapshot.nodes[child]
                    if node.isDirectory {
                        if expandable(child) { pending.append(child) }
                    } else if installerSuffixes.contains(node.name.pathSuffix) {
                        claim(child, CleanupCategories.installers)
                    }
                }
            }
        }
        return group(items)
    }

    private static func group(_ items: [CleanupItem]) -> [CleanupGroup] {
        Dictionary(grouping: items, by: \.category)
            .map { CleanupGroup(category: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { lhs, rhs in
                let order = CleanupSafety.allCases
                let left = order.firstIndex(of: lhs.category.safety)!
                let right = order.firstIndex(of: rhs.category.safety)!
                return left == right ? lhs.size > rhs.size : left < right
            }
    }
}

public struct StaleFile: Sendable {
    public let node: Int
    public let path: String
    public let size: Int64
    public let lastUsed: Date?
    public let modified: Date?
    public let added: Date?
    public let isInICloud: Bool

    public var lastActivity: Date? { [lastUsed, modified, added].compactMap { $0 }.max() }
}

public struct CloudDestination: Hashable, Sendable {
    public enum Service: String, Sendable {
        case iCloudDrive, googleDrive, oneDrive, dropbox, box, other
    }

    public let service: Service
    public let title: String
    public let root: URL
}

public enum CloudOffload {
    public static let folders = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
        "Library/Mobile Documents/com~apple~CloudDocs",
    ]
    public static let archiveFolder = "Архив с Mac"

    public static func staleFiles(
        in snapshot: ScanSummary, minSize: Int64, olderThanDays days: Double,
        home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now
    ) -> [StaleFile] {
        let cutoff = now.addingTimeInterval(-days * 86_400)
        let homePath = home.standardizedFileURL.path
        var result: [StaleFile] = []
        for folder in folders {
            let folderPath = homePath + "/" + folder
            guard let folderID = snapshot.locate(folderPath) else { continue }
            var files: [Int] = []
            var stack = [folderID]
            while let id = stack.popLast() {
                for child in snapshot.children(of: id) {
                    let node = snapshot.nodes[child]
                    if node.isDirectory {
                        if !snapshot.kinds[Int(node.kind)].isPackage, !node.name.hasPrefix(".") { stack.append(child) }
                    } else if node.allocated >= minSize {
                        files.append(child)
                    }
                }
            }
            guard !files.isEmpty else { continue }
            let indexed = spotlightDates(in: folderPath, minSize: minSize)
            for id in files {
                let path = snapshot.displayPath(of: id)
                let dates = indexed[path] ?? fileDates(path)
                let file = StaleFile(
                    node: id, path: path, size: snapshot.nodes[id].allocated,
                    lastUsed: dates.lastUsed, modified: dates.modified, added: dates.added,
                    isInICloud: (try? URL(filePath: path).resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
                )
                guard let activity = file.lastActivity, activity < cutoff else { continue }
                result.append(file)
            }
        }
        return result.sorted { $0.size > $1.size }
    }

    public static func destinations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CloudDestination] {
        let fm = FileManager.default
        var result: [CloudDestination] = []
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        if fm.fileExists(atPath: iCloud.path) {
            result.append(CloudDestination(service: .iCloudDrive, title: "iCloud Drive", root: iCloud))
        }
        let storage = home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        let names = (try? fm.contentsOfDirectory(atPath: storage.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            let provider = storage.appending(path: name, directoryHint: .isDirectory)
            if name.hasPrefix("GoogleDrive") {
                let drive = ["My Drive", "Мой диск"].map { provider.appending(path: $0, directoryHint: .isDirectory) }
                    .first { fm.fileExists(atPath: $0.path) } ?? provider
                let account = name.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
                result.append(CloudDestination(service: .googleDrive, title: account.map { "Google Drive (\($0))" } ?? "Google Drive", root: drive))
            } else if name.hasPrefix("OneDrive") {
                result.append(CloudDestination(service: .oneDrive, title: "OneDrive", root: provider))
            } else if name.hasPrefix("Dropbox") {
                result.append(CloudDestination(service: .dropbox, title: "Dropbox", root: provider))
            } else if name.hasPrefix("Box") {
                result.append(CloudDestination(service: .box, title: "Box", root: provider))
            } else {
                result.append(CloudDestination(service: .other, title: name, root: provider))
            }
        }
        return result
    }

    public static func target(for file: URL, in destination: CloudDestination,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let homeComponents = home.standardizedFileURL.pathComponents
        let fileComponents = file.standardizedFileURL.pathComponents
        let relative = fileComponents.starts(with: homeComponents)
            ? Array(fileComponents.dropFirst(homeComponents.count)) : [file.lastPathComponent]
        return relative.reduce(destination.root.appending(path: archiveFolder, directoryHint: .isDirectory)) {
            $0.appending(path: $1)
        }
    }

    @discardableResult
    public static func move(_ file: URL, to destination: CloudDestination,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let fm = FileManager.default
        var target = target(for: file, in: destination, home: home)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stem = target.deletingPathExtension().lastPathComponent
        let suffix = target.pathExtension
        var attempt = 2
        while fm.fileExists(atPath: target.path) {
            let name = suffix.isEmpty ? "\(stem) \(attempt)" : "\(stem) \(attempt).\(suffix)"
            target = target.deletingLastPathComponent().appending(path: name)
            attempt += 1
        }
        try fm.moveItem(at: file, to: target)
        return target
    }

    public static func removeLocalCopy(_ file: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: file)
    }

    private struct Dates {
        var lastUsed: Date?
        var modified: Date?
        var added: Date?
    }

    private static func fileDates(_ path: String) -> Dates {
        var info = stat()
        guard lstat(path, &info) == 0 else { return Dates() }
        func date(_ spec: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1e9)
        }
        return Dates(lastUsed: nil, modified: date(info.st_mtimespec), added: date(info.st_birthtimespec))
    }

    private static func spotlightDates(in scope: String, minSize: Int64) -> [String: Dates] {
        let attributes = ["kMDItemLastUsedDate", "kMDItemContentModificationDate", "kMDItemDateAdded"] as [CFString]
        let text = "kMDItemPhysicalSize >= \(minSize)" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, text, attributes as CFArray, nil) else { return [:] }
        MDQuerySetSearchScope(query, [scope] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [:] }
        MDQueryStop(query)
        var result: [String: Dates] = [:]
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            func value(_ attribute: CFString) -> Date? {
                MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index)
                    .map { Unmanaged<CFDate>.fromOpaque($0).takeUnretainedValue() as Date }
            }
            result[path] = Dates(lastUsed: value(attributes[0]), modified: value(attributes[1]), added: value(attributes[2]))
        }
        return result
    }
}

public extension ScanSummary {
    func locate(_ path: String) -> Int? {
        if let id = find(URL(filePath: path)) { return id }
        let data = "/System/Volumes/Data"
        guard root.path == data || root.path.hasPrefix(data + "/"), !path.hasPrefix(data) else { return nil }
        return find(URL(filePath: data + path))
    }

    func displayPath(of id: Int) -> String {
        let path = url(for: id).path
        let data = "/System/Volumes/Data"
        guard path.hasPrefix(data + "/") else { return path }
        return String(path.dropFirst(data.count))
    }
}

extension String {
    var pathSuffix: String {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return "" }
        return self[index(after: dot)...].lowercased()
    }
}
