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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Disk Inventory").font(.title2.weight(.semibold))
                    Text("Choose a volume or folder to scan")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: refresh) { Label("Refresh Volumes", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .help("Refresh Volumes")
            }
            List(selection: $selection) {
                ForEach(volumes) { volume in
                    let low = volume.usage.map { $0.capacity > 0 && Double($0.free) / Double($0.capacity) < 0.1 } ?? false
                    HStack(spacing: 12) {
                        Image(systemName: volume.url.path == "/" ? "internaldrive.fill" : "externaldrive")
                            .font(.system(size: 22, weight: .light))
                            .frame(width: 32)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(volume.name).font(.body.weight(.medium))
                            if let usage = volume.usage, usage.capacity > 0 {
                                ProgressView(value: Double(max(0, usage.capacity - usage.free)), total: Double(usage.capacity))
                                    .tint(low ? .orange : .secondary)
                                    .accessibilityLabel("Space used")
                                Text("\(formatSize(usage.free)) free of \(formatSize(usage.capacity))\(low ? " · almost full" : "")")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            } else {
                                Text(volume.url.path).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(volume.url)
                }
            }
            .listStyle(.bordered)
            .accessibilityLabel("Mounted volumes")
            .contextMenu(forSelectionType: URL.self) { _ in
                EmptyView()
            } primaryAction: { urls in
                if let url = urls.first { open(url) }
            }
            HStack {
                Button("Open Folder…", action: choose)
                Spacer()
                Button(selection.map(openScans.contains) == true ? "Show Scan" : "Scan Volume") {
                    if let selection { open(selection) }
                }
                    .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 330)
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
    private var adviceObservers: [any NSObjectProtocol] = []
    var launchCleanup = CommandLine.arguments.contains("--cleanup")
    var testLocation: URL?
    var testTrash = false
    var testLayout = false
    var testSettingsDomain: String?
    var screenshots: (folder: URL, directory: URL)?

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

        let center = DistributedNotificationCenter.default()
        adviceObservers.append(center.addObserver(forName: .init(AdviceStore.changedNotification), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.documents.forEach { $0.reloadAdvice() } }
        })
        adviceObservers.append(center.addObserver(forName: .init(AdviceStore.showNotification), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showCleanup() }
        })

        if let screenshots {
            runScreenshots(screenshots.folder, to: screenshots.directory)
        } else if testTrash {
            runTrashSmokeTest()
        } else if let testLocation {
            if testLayout {
                runLayoutSmokeTest(testLocation)
            } else if let testSettingsDomain {
                runSettingsSmokeTest(testLocation, domain: testSettingsDomain)
            } else {
                runSmokeTest(testLocation)
            }
        } else if launchCleanup {
            showCleanup()
        } else if documents.isEmpty {
            scanVolumes()
        }
    }

    @objc func showCleanup() {
        NSApp.activate()
        if let document = documents.last(where: { $0.canShowScan }) {
            if document.window?.isMiniaturized == true { document.window?.deminiaturize(nil) }
            document.window?.makeKeyAndOrderFront(nil)
            document.cleanUp()
        } else {
            open(FileManager.default.homeDirectoryForCurrentUser).cleanUp()
        }
    }

    @objc func scanHome() {
        open(FileManager.default.homeDirectoryForCurrentUser)
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
        if testLocation == nil, !testTrash, screenshots == nil { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
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
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for page in PreferencesPage.allCases {
                let controller = NSHostingController(rootView: page.view.defaultAppStorage(Settings.store))
                controller.sizingOptions = .preferredContentSize
                let item = NSTabViewItem(viewController: controller)
                item.label = page.title
                item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
                tabs.addTabViewItem(item)
            }
            tabs.selectedTabViewItemIndex = min(Settings.store.integer(forKey: "preferencesTab"), PreferencesPage.allCases.count - 1)
            let window = NSWindow(contentViewController: tabs)
            window.title = "Disk Inventory Settings"
            window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.center()
            preferences = window
        }
        preferences?.makeKeyAndOrderFront(nil)
    }

    private var helpWindow: NSWindow?

    @objc private func showHelp() {
        if helpWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HelpView()))
            window.title = "Disk Inventory Help"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 420))
            window.center()
            helpWindow = window
        }
        helpWindow?.makeKeyAndOrderFront(nil)
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
        add(file, "Quick Look", #selector(ScanWindow.quickLook(_:)), "y")
        add(file, "Reveal in Finder", #selector(ScanWindow.revealInFinder), "r")
        add(file, "Get Info", #selector(ScanWindow.inspect), "i")
        add(file, "Move to Trash…", #selector(ScanWindow.moveToTrash), "\u{8}")
        add(file, "Clean Up…", #selector(ScanWindow.cleanUp), "k", .shift)

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", .shift)
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Delete", #selector(NSText.delete(_:)))
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
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
        add(view, "Rescan Selection", #selector(ScanWindow.refreshSelection), "r", .shift)
        add(view, "Rescan", #selector(ScanWindow.refreshAll), "r", .option)
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
        add(view, "Show Inspector", #selector(ScanWindow.toggleDetails), "i", .option)
        add(view, "Show Largest Files", #selector(ScanWindow.toggleList), "l")

        let windows = submenu("Window")
        add(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windows, "Zoom Window", #selector(NSWindow.performZoom(_:)))
        windows.addItem(.separator())
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
        guard let tabs = window.contentViewController as? NSTabViewController else { return false }
        for index in [1, 2, 0] {
            tabs.selectedTabViewItemIndex = index
            try? await Task.sleep(for: .milliseconds(150))
            view.layoutSubtreeIfNeeded()
            guard window.isVisible, window.contentView?.bounds.height ?? 0 >= 300, window.contentView?.bounds.width ?? 0 >= 500 else { return false }
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

    private func runScreenshots(_ location: URL, to directory: URL) {
        Task { @MainActor in
            let document = open(location)
            document.window?.setFrame(NSRect(x: 80, y: 40, width: 1280, height: 940), display: true)
            let deadline = ContinuousClock.now + .seconds(120)
            while !document.testReady, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let shots: [(name: String, appearance: NSAppearance.Name, cleanup: Bool)] = [
                ("main-window", .aqua, false), ("main-window-dark", .darkAqua, false), ("cleanup-tab", .aqua, true),
            ]
            for shot in shots where document.testReady {
                NSApp.appearance = NSAppearance(named: shot.appearance)
                if shot.cleanup { document.cleanUp() }
                try? await Task.sleep(for: .seconds(2))
                guard document.captureWindow(to: directory.appending(path: shot.name + ".png")) else { break }
                print(shot.name)
            }
            fflush(nil)
            exit(document.testReady ? EXIT_SUCCESS : EXIT_FAILURE)
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


private struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Treemap", "Each rectangle is a file or folder and its area is its size. Folders that are large enough show their name and size in a header. The file tree and the map share one selection. Double-click a folder to zoom in, use the path bar or Zoom Out (Cmd-Up) to go back, the arrow keys to move between tiles and Space to preview.")
                section("Kinds and Largest Files", "Kinds lists space by file type in the colors of the map; choosing a kind highlights its tiles. Largest Files lists files by size and searches by name, kind or folder; matches stay highlighted on the map.")
                section("Clean Up", "The Clean Up tab sorts what can go by how safe it is, shows advice Claude sent through the inventory MCP server with a reason for each item, and lists big files nobody opened for months that can move to iCloud Drive or Google Drive. Nothing is removed until you confirm, and removed items go to the Trash.")
                section("Full Disk Access", "Without Full Disk Access macOS hides Mail, Messages, Safari and parts of Library, and may ask about Documents and Desktop during a scan. Turn on Disk Inventory in System Settings, Privacy & Security, Full Disk Access, then reopen the app and rescan.")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
