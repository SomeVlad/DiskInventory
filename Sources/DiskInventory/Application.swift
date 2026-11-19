import AppKit
import SwiftUI
import UniformTypeIdentifiers
import InventoryCore

struct MountedVolume: Identifiable {
    let url: URL
    let name: String
    let usage: VolumeUsage?
    var id: URL { url }
}

struct VolumePicker: View {
    let volumes: [MountedVolume]
    let openScans: Set<URL>
    let open: (URL) -> Void
    let choose: () -> Void
    let refresh: () -> Void
    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 53, height: 53)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Disk Inventory").font(.title2.weight(.semibold))
                    Text("Choose a volume or folder to scan.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: refresh) { Label("Refresh Volumes", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .help("Refresh Volumes")
            }
            List(selection: $selection) {
                ForEach(volumes) { volume in
                    HStack(spacing: 11) {
                        Image(systemName: volume.url.path == "/" ? "internaldrive.fill" : "externaldrive")
                            .font(.system(size: 22, weight: .light))
                            .frame(width: 29)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(volume.name).font(.body.weight(.medium))
                            if let usage = volume.usage, usage.capacity > 0 {
                                ProgressView(value: Double(max(0, usage.capacity - usage.free)), total: Double(usage.capacity))
                                    .tint(.accentColor)
                                    .accessibilityLabel("Space used")
                                Text("\(formatSize(usage.free)) free of \(formatSize(usage.capacity))")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            } else {
                                Text(volume.url.path).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(volume.url) }
                    .tag(volume.url)
                }
            }
            .listStyle(.bordered)
            .accessibilityLabel("Mounted volumes")
            HStack {
                Button("Open Folder…", action: choose)
                Spacer()
                Button(selection.map(openScans.contains) == true ? "Show Scan" : "Scan Volume") {
                    if let selection { open(selection) }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 330)
        .onAppear { selection = volumes.first?.url }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in open(url) }
            }
            return true
        }
    }
}

@MainActor final class ApplicationController: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var documents: [ScanWindow] = []
    private var volumeScans: [String: ScanWindow] = [:]
    private var launcher: NSWindow?
    private var preferences: NSWindow?
    private var settingsObserver: (any NSObjectProtocol)?
    private var volumeObservers: [any NSObjectProtocol] = []
    private var refreshTimer: Timer?
    var testLocation: URL?
    var testTrash = false
    var testLayout = false
    var testSettingsDomain: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        applyWindowAppearance()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: Settings.store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSettingsUpdate() }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                let url = event.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didRenameVolumeNotification || url == nil {
                        self?.volumeScans.removeAll()
                    } else if let url {
                        self?.volumeScans.removeValue(forKey: url.standardizedFileURL.path)
                    }
                    self?.refreshVolumes()
                }
            }
            volumeObservers.append(observer)
        }

        if testTrash {
            runTrashSmokeTest()
        } else if let testLocation {
            if testLayout {
                runLayoutSmokeTest(testLocation)
            } else if let testSettingsDomain {
                runSettingsSmokeTest(testLocation, domain: testSettingsDomain)
            } else {
                runSmokeTest(testLocation)
            }
        } else if documents.isEmpty {
            scanVolumes()
        }
    }

    private func scheduleSettingsUpdate() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyWindowAppearance()
                self?.documents.forEach { $0.applySettings() }
            }
        }
    }

    private func applyWindowAppearance() {
        let appearance = Settings.appearance.appearance
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { scanVolumes() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    private func scanLocation(_ url: URL) -> URL {
        if url.standardizedFileURL.path == "/" {
            let data = URL(filePath: "/System/Volumes/Data", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: data.path) { return data }
        }
        return url
    }

    @discardableResult
    func open(_ url: URL, hideLauncher: Bool = true, asVolume: Bool = false) -> ScanWindow {
        if hideLauncher { launcher?.orderOut(nil) }
        let key = url.standardizedFileURL.path
        if asVolume, let existing = volumeScans[key], existing.canShowScan {
            if existing.window?.isMiniaturized == true { existing.window?.deminiaturize(nil) }
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let document = ScanWindow(location: scanLocation(url))
        documents.append(document)
        if asVolume { volumeScans[key] = document }
        document.onClose = { [weak self] closed in
            guard let self else { return }
            self.documents.removeAll { $0 === closed }
            if self.volumeScans[key] === closed { self.volumeScans.removeValue(forKey: key) }
            if self.launcher?.isVisible == true { self.refreshVolumes() }
        }
        document.showWindow(nil)
        document.window?.makeKeyAndOrderFront(nil)
        document.scan(restore: false)
        if testLocation == nil, !testTrash { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        return document
    }

    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.prompt = "Scan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        if let parent = NSApp.keyWindow {
            panel.beginSheetModal(for: parent) { [weak self] response in
                if response == .OK { panel.urls.forEach { self?.open($0) } }
            }
        } else {
            panel.begin { [weak self] response in
                if response == .OK { panel.urls.forEach { self?.open($0) } }
            }
        }
    }

    @objc func scanVolumes() {
        if launcher == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Volumes"
            window.minSize = NSSize(width: 480, height: 335)
            window.isReleasedWhenClosed = false
            launcher = window
            window.center()
        }
        refreshVolumes()
        launcher?.makeKeyAndOrderFront(nil)
    }

    private func refreshVolumes() {
        guard let launcher else { return }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.sorted {
            if $0.path == "/" { return $1.path != "/" }
            if $1.path == "/" { return false }
            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? url.lastPathComponent
            return MountedVolume(url: url, name: name, usage: VolumeUsage.read(url))
        }
        launcher.contentViewController = NSHostingController(rootView: VolumePicker(
            volumes: volumes,
            openScans: Set(volumes.filter { volumeScans[$0.url.standardizedFileURL.path]?.canShowScan == true }.map(\.url)),
            open: { [weak self] url in
                let isVolume = volumes.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
                self?.open(url, asVolume: isVolume)
            },
            choose: { [weak self] in self?.chooseFolder() },
            refresh: { [weak self] in self?.refreshVolumes() }
        ))
    }

    @objc private func showPreferences() {
        if preferences == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView().defaultAppStorage(Settings.store)))
            window.title = "Disk Inventory Settings"
            window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable]
            window.center()
            preferences = window
        }
        preferences?.makeKeyAndOrderFront(nil)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Disk Inventory Help"
        alert.informativeText = """
        Open a folder or volume. Each rectangle represents an item and its area shows its size. The file tree and treemap follow the same selection.

        Double-click a folder to zoom. Use the path bar or Zoom Out to go back. The Kinds panel matches the colors on the map. Double-click a kind to list its files.

        If a whole-disk scan reports skipped locations, you can add Disk Inventory to Full Disk Access in System Settings, then relaunch and rescan.
        """
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    @objc(scanSelection:userData:error:)
    func scanSelection(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let directories = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if directories.isEmpty {
            error.pointee = "Select a folder or volume in Finder."
        } else {
            directories.forEach { open($0) }
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            menu.addItem(item)
            return submenu
        }
        func add(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String = "", _ extra: NSEvent.ModifierFlags = [], own: Bool = false) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, extra]
            if own { item.target = self }
            menu.addItem(item)
        }
        let app = submenu("Disk Inventory")
        add(app, "About Disk Inventory", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Settings…", #selector(showPreferences), ",", own: true)
        app.addItem(.separator())
        let service = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        service.submenu = NSMenu()
        app.addItem(service)
        NSApp.servicesMenu = service.submenu
        app.addItem(.separator())
        add(app, "Hide Disk Inventory", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", .option)
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit Disk Inventory", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Open Folder…", #selector(chooseFolder), "o", own: true)
        add(file, "Show Volumes", #selector(scanVolumes), "o", .shift, own: true)
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        file.addItem(.separator())
        add(file, "Open", #selector(ScanWindow.openSelected), "o", .option)
        add(file, "Reveal in Finder", #selector(ScanWindow.revealInFinder), "r")
        add(file, "Get Info", #selector(ScanWindow.inspect), "i")
        add(file, "Move to Trash…", #selector(ScanWindow.moveToTrash), "\u{8}")

        let edit = submenu("Edit")
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Copy File", #selector(ScanWindow.copySelection), "c", .shift)
        add(edit, "Copy Path", #selector(ScanWindow.copyPath), "c", [.shift, .option])
        edit.addItem(.separator())
        add(edit, "Find…", #selector(ScanWindow.findFiles), "f")
        add(edit, "Find Next", #selector(ScanWindow.findNext), "g")
        add(edit, "Use Selection for Find", #selector(ScanWindow.findSelection), "e")
        add(edit, "Scroll to Selection", #selector(ScanWindow.scrollToSelection), "j")

        let view = submenu("View")
        add(view, "Zoom In", #selector(ScanWindow.zoomIn), "+")
        add(view, "Zoom Out", #selector(ScanWindow.zoomOut), "-")
        add(view, "Zoom to Root", #selector(ScanWindow.zoomRoot), "0")
        view.addItem(.separator())
        add(view, "Refresh Selection", #selector(ScanWindow.refreshSelection), "r", .shift)
        add(view, "Refresh All", #selector(ScanWindow.refreshAll), "r", .option)
        view.addItem(.separator())
        for (title, key) in [
            ("Show Package Contents", "packages"), ("Show Allocated File Size", "physical"),
            ("Show Free Space", "free"), ("Show Other Space", "other"), ("Ignore Legacy Creator Codes", "ignoreCreator"),
            ("Synchronize Selection with Finder", "syncFinder")
        ] {
            let item = NSMenuItem(title: title, action: #selector(toggleOption(_:)), keyEquivalent: "")
            item.representedObject = key
            item.target = self
            view.addItem(item)
        }
        view.addItem(.separator())
        add(view, "Toggle Inspector", #selector(ScanWindow.toggleDetails), "i", .option)

        let windows = submenu("Window")
        add(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windows, "Zoom Window", #selector(NSWindow.performZoom(_:)))
        windows.addItem(.separator())
        add(windows, "Selection List", #selector(ScanWindow.toggleList), "l")
        add(windows, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windows

        let help = submenu("Help")
        add(help, "Disk Inventory Help", #selector(showHelp), "?", own: true)
        NSApp.helpMenu = help
        NSApp.mainMenu = menu
    }

    @objc private func toggleOption(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        Settings.store.set(!Settings.bool(key, default: key == "physical" || key == "ignoreCreator"), forKey: key)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let key = menuItem.representedObject as? String {
            menuItem.state = Settings.bool(key, default: key == "physical" || key == "ignoreCreator") ? .on : .off
        }
        return true
    }

    private func runTrashSmokeTest() {
        Task { @MainActor in
            let fixture = FileManager.default.temporaryDirectory
                .appending(path: "DiskInventoryTrashTest-" + UUID().uuidString, directoryHint: .isDirectory)
                .resolvingSymlinksInPath()
            let outcome: Result<Duration, Error>
            do {
                try await Task.detached {
                    let folder = fixture.appending(path: "Dense", directoryHint: .isDirectory)
                    let data = Data([1])
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: fixture.appending(path: "Retained.txt"))
                    for index in 0..<30_000 {
                        try data.write(to: folder.appending(path: "item-\(index).txt"))
                    }
                }.value
                let window = open(fixture)
                defer { window.close() }
                outcome = .success(try await window.exerciseTrash(in: fixture))
            } catch {
                outcome = .failure(error)
            }
            await Task.detached { try? FileManager.default.removeItem(at: fixture) }.value
            switch outcome {
            case let .success(longest):
                print("Moved a file and its 29,999-item folder to Trash. Maximum interval between 16 ms UI probes: \(longest).")
                fflush(nil)
                exit(EXIT_SUCCESS)
            case let .failure(error):
                print("Trash workflow failed: \(error.localizedDescription)")
                fflush(nil)
                exit(EXIT_FAILURE)
            }
        }
    }

    private func runSettingsSmokeTest(_ location: URL, domain: String) {
        Task { @MainActor in
            let document = open(location)
            showPreferences()
            let store = Settings.store
            let appearance = await checkWindowAppearance(on: document.window)
            let visuals = await document.exerciseVisualSettings()
            let stored = UserDefaults(suiteName: domain)
            let persists = stored?.string(forKey: "treemapPalette") == TreemapPalette.highContrast.rawValue
                && stored?.bool(forKey: "treemapFolderBorders") == true
            let pages = await checkPreferencesPages()
            let ready = preferences?.isVisible == true && appearance && visuals && persists && pages
            if ready, let path = ProcessInfo.processInfo.environment["DISK_INVENTORY_SETTINGS_PREVIEW"],
               let view = preferences?.contentView {
                store.set(WindowAppearance.light.rawValue, forKey: "appearance")
                store.set(TreemapPalette.ocean.rawValue, forKey: "treemapPalette")
                store.set(true, forKey: "treemapLabels")
                try? await Task.sleep(for: .milliseconds(250))
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: image)
                    try? image.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
                }
            }
            document.close()
            preferences?.close()
            store.removePersistentDomain(forName: domain)
            print(ready ? "Window appearance, all palettes, live map settings, saved preferences and selection preservation passed."
                        : "Settings check failed (appearance \(appearance), live visuals \(visuals), persistence \(persists), pages \(pages)).")
            fflush(nil)
            exit(ready ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    private func checkPreferencesPages() async -> Bool {
        guard let window = preferences, let view = window.contentView else { return false }
        for page in [PreferencesView.Page.scanning, .behavior, .appearance] {
            Settings.store.set(page.rawValue, forKey: "preferencesPage")
            try? await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            guard view.bounds.height >= 540, view.bounds.width >= 600, window.isVisible else { return false }
        }
        return true
    }

    private func checkWindowAppearance(on documentWindow: NSWindow?) async -> Bool {
        for appearance in [WindowAppearance.dark, .light, .system] {
            Settings.store.set(appearance.rawValue, forKey: "appearance")
            let desired = appearance.appearance?.name
            let deadline = ContinuousClock.now + .seconds(3)
            while NSApp.appearance?.name != desired, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if NSApp.appearance?.name != desired { return false }
            if let desired {
                try? await Task.sleep(for: .milliseconds(100))
                for window in [documentWindow, preferences] {
                    guard window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == desired else { return false }
                }
            }
        }
        return true
    }

    private func runLayoutSmokeTest(_ location: URL) {
        Task { @MainActor in
            NSApp.activate()
            let document = open(location)
            guard await document.exerciseLayout() else {
                print("Layout workflow failed.")
                fflush(nil)
                exit(EXIT_FAILURE)
            }
            document.toggleList()
            let layout = document.layoutSignature
            if let path = ProcessInfo.processInfo.environment["DISK_INVENTORY_PREVIEW"] {
                try? await Task.sleep(for: .milliseconds(240))
                document.captureContent(to: URL(filePath: path))
            }
            document.close()
            let restored = open(location)
            guard restored.layoutSignature == layout else {
                print("Layout restoration failed. Expected \(layout), got \(restored.layoutSignature).")
                fflush(nil)
                exit(EXIT_FAILURE)
            }
            restored.close()
            print("Header resize and reorder in three tables, both split dividers, layout restoration, Return activation, search filter and selection checks passed.")
            fflush(nil)
            exit(EXIT_SUCCESS)
        }
    }

    private func runSmokeTest(_ location: URL) {
        Task { @MainActor in
            scanVolumes()
            guard launcher?.contentViewController != nil else {
                exit(EXIT_FAILURE)
            }
            showPreferences()
            preferences?.close()
            for pass in 0..<3 {
                let document = open(location, asVolume: true)
                guard open(location, asVolume: true) === document else {
                    print("Volume selection started a duplicate scan.")
                    fflush(nil)
                    exit(EXIT_FAILURE)
                }
                let deadline = ContinuousClock.now + .seconds(15)
                while !document.testReady, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if pass == 0, document.testReady,
                   let path = ProcessInfo.processInfo.environment["DISK_INVENTORY_PREVIEW"] {
                    document.captureContent(to: URL(filePath: path))
                }
                guard let result = document.snapshot, result.nodes.count > 1, document.testReady,
                      await document.exerciseWorkflow(), document.window?.isVisible == true else {
                    print("Window workflow failed.")
                    fflush(nil)
                    exit(EXIT_FAILURE)
                }
                document.close()
            }
            print("Volume picker, volume scan reuse, preferences, scan, treemap, synchronized selection, zoom, search, refresh and close passed.")
            fflush(nil)
            exit(EXIT_SUCCESS)
        }
    }
}
