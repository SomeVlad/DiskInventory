import AppKit
import InventoryCore
import SwiftUI

@MainActor @Observable final class CleanupModel {
    typealias Apply = @MainActor (_ removed: [URL], _ refreshed: [URL]) async -> ScanSummary?

    private(set) var snapshot: ScanSummary
    private let apply: Apply
    private(set) var groups: [CleanupGroup] = []
    private(set) var stale: [StaleFile] = []
    private(set) var analyzing = true
    private(set) var working: String?
    var selected: Set<Int> = []
    var staleSelected: Set<Int> = []
    var days = 180
    var minimum: Int64 = 100 << 20
    let destinations = CloudOffload.destinations()
    var destination: CloudDestination?
    var failure: String?
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(snapshot: ScanSummary, apply: @escaping Apply) {
        self.snapshot = snapshot
        self.apply = apply
        destination = destinations.first
    }

    var removable: [CleanupItem] {
        groups.filter { $0.category != CleanupCategories.trash }.flatMap(\.items)
    }

    var chosen: [CleanupItem] { removable.filter { selected.contains($0.node) } }
    var chosenSize: Int64 { chosen.reduce(0) { $0 + $1.size } }
    var chosenLocal: [StaleFile] { stale.filter { staleSelected.contains($0.node) && !$0.isInICloud } }
    var chosenInICloud: [StaleFile] { stale.filter { staleSelected.contains($0.node) && $0.isInICloud } }

    func total(_ safety: CleanupSafety) -> Int64 {
        groups.filter { $0.category.safety == safety }.reduce(0) { $0 + $1.size }
    }

    func display(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    func path(of item: CleanupItem) -> String { display(snapshot.displayPath(of: item.node)) }

    func url(of node: Int) -> URL { URL(filePath: snapshot.displayPath(of: node)) }

    func analyze() async {
        analyzing = true
        let snapshot = snapshot
        let days = Double(days)
        let minimum = minimum
        async let groups = Task.detached(priority: .userInitiated) { CleanupAnalyzer.analyze(snapshot) }.value
        async let stale = Task.detached(priority: .userInitiated) {
            CloudOffload.staleFiles(in: snapshot, minSize: minimum, olderThanDays: days)
        }.value
        (self.groups, self.stale) = await (groups, stale)
        selected = Set(self.groups.filter { $0.category.safety == .safe && $0.category != CleanupCategories.trash }
            .flatMap { $0.items.map(\.node) })
        staleSelected = []
        analyzing = false
    }

    func findStale() async {
        let snapshot = snapshot
        let days = Double(days)
        let minimum = minimum
        stale = await Task.detached(priority: .userInitiated) {
            CloudOffload.staleFiles(in: snapshot, minSize: minimum, olderThanDays: days)
        }.value
        staleSelected = []
    }

    func trashChosen() async {
        let urls = chosen.map { url(of: $0.node) }
        working = "Moving \(urls.count) items to the Trash…"
        let outcome = await Task.detached(priority: .userInitiated) { () -> ([URL], [String]) in
            var done: [URL] = []
            var errors: [String] = []
            for url in urls {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    done.append(url)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return (done, errors)
        }.value
        await finish(removed: outcome.0, refreshed: [], errors: outcome.1)
    }

    func moveChosen() async {
        guard let destination else { return }
        let urls = chosenLocal.map { URL(filePath: $0.path) }
        working = "Moving \(urls.count) files to \(destination.title)…"
        let outcome = await Task.detached(priority: .userInitiated) { () -> ([URL], [String]) in
            var done: [URL] = []
            var errors: [String] = []
            for url in urls {
                do {
                    try CloudOffload.move(url, to: destination)
                    done.append(url)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return (done, errors)
        }.value
        let refreshed = snapshot.locate(destination.root.path) == nil ? [] : [destination.root]
        await finish(removed: outcome.0, refreshed: refreshed, errors: outcome.1)
    }

    func removeDownloads() async {
        let urls = chosenInICloud.map { URL(filePath: $0.path) }
        working = "Removing \(urls.count) downloads…"
        let outcome = await Task.detached(priority: .userInitiated) { () -> ([URL], [String]) in
            var done: [URL] = []
            var errors: [String] = []
            for url in urls {
                do {
                    try CloudOffload.removeLocalCopy(url)
                    done.append(url)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return (done, errors)
        }.value
        await finish(removed: [], refreshed: outcome.0, errors: outcome.1)
    }

    private func finish(removed: [URL], refreshed: [URL], errors: [String]) async {
        working = "Updating the scan…"
        if let updated = await apply(removed, refreshed) { snapshot = updated }
        working = nil
        failure = errors.isEmpty ? nil : errors.prefix(5).joined(separator: "\n")
        await analyze()
    }
}

private enum CleanupTab: Hashable {
    case remove, cloud
}

struct CleanupView: View {
    @Bindable var model: CleanupModel
    @State private var tab = CleanupTab.remove
    @State private var confirmTrash = false
    @State private var confirmMove = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $tab) {
                Text("Remove").tag(CleanupTab.remove)
                Text("Move to Cloud").tag(CleanupTab.cloud)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 10)
            Divider()
            Group {
                if model.analyzing {
                    ProgressView("Looking for things to clean up…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tab == .remove {
                    removeList
                } else {
                    cloudList
                }
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 640, minHeight: 440)
        .task { await model.analyze() }
    }

    private var removeList: some View {
        List {
            ForEach(CleanupSafety.allCases, id: \.self) { safety in
                let groups = model.groups.filter { $0.category.safety == safety }
                if !groups.isEmpty {
                    Section {
                        ForEach(groups, id: \.category.id) { group in
                            CategoryRow(model: model, group: group)
                        }
                    } header: {
                        HStack {
                            Text(safety.title)
                            Spacer()
                            Text(formatSize(model.total(safety))).monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.groups.isEmpty {
                ContentUnavailableView("Nothing to Clean Up", systemImage: "checkmark.circle",
                                       description: Text("No caches, build artifacts or installers were found in this scan."))
            }
        }
    }

    private var cloudList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Not opened for", selection: $model.days) {
                    Text("3 months").tag(90)
                    Text("6 months").tag(180)
                    Text("1 year").tag(365)
                    Text("2 years").tag(730)
                }
                .fixedSize()
                Picker("Larger than", selection: $model.minimum) {
                    Text("50 MB").tag(Int64(50 << 20))
                    Text("100 MB").tag(Int64(100 << 20))
                    Text("500 MB").tag(Int64(500 << 20))
                    Text("1 GB").tag(Int64(1 << 30))
                }
                .fixedSize()
                Spacer()
                if !model.destinations.isEmpty {
                    Picker("Move to", selection: $model.destination) {
                        ForEach(model.destinations, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            List {
                ForEach(model.stale, id: \.node) { file in
                    StaleRow(model: model, file: file)
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.stale.isEmpty {
                    ContentUnavailableView(
                        "No Forgotten Files", systemImage: "clock",
                        description: Text("Nothing this large went unopened that long in Desktop, Documents, Downloads, Movies, Music, Pictures or iCloud Drive."))
                }
            }
        }
        .onChange(of: model.days) { Task { await model.findStale() } }
        .onChange(of: model.minimum) { Task { await model.findStale() } }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            if let working = model.working {
                ProgressView().controlSize(.small)
                Text(working).foregroundStyle(.secondary)
            } else if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).lineLimit(2)
            } else if tab == .remove {
                Text("\(model.chosen.count) selected · \(formatSize(model.chosenSize))").foregroundStyle(.secondary).monospacedDigit()
            } else {
                let size = (model.chosenLocal + model.chosenInICloud).reduce(Int64(0)) { $0 + $1.size }
                Text("\(model.chosenLocal.count + model.chosenInICloud.count) selected · \(formatSize(size))").foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if tab == .remove {
                Button("Move to Trash…", role: .destructive) { confirmTrash = true }
                    .disabled(model.chosen.isEmpty || model.working != nil)
                    .keyboardShortcut(.delete, modifiers: .command)
            } else {
                Button("Remove Download") { Task { await model.removeDownloads() } }
                    .disabled(model.chosenInICloud.isEmpty || model.working != nil)
                    .help("Keep the file in iCloud Drive and free the space it takes on this Mac")
                Button("Move to \(model.destination?.title ?? "Cloud")…") { confirmMove = true }
                    .disabled(model.chosenLocal.isEmpty || model.destination == nil || model.working != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .confirmationDialog("Move \(model.chosen.count) items to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { Task { await model.trashChosen() } }
        } message: {
            Text("They free \(formatSize(model.chosenSize)) once you empty the Trash.")
        }
        .confirmationDialog("Move \(model.chosenLocal.count) files to \(model.destination?.title ?? "the cloud")?", isPresented: $confirmMove) {
            Button("Move") { Task { await model.moveChosen() } }
        } message: {
            Text("They go to “\(CloudOffload.archiveFolder)” and keep their folder structure. The space comes back after they finish uploading and you remove the local copies.")
        }
    }
}

private struct CategoryRow: View {
    @Bindable var model: CleanupModel
    let group: CleanupGroup

    private var isTrash: Bool { group.category == CleanupCategories.trash }

    private var allSelected: Binding<Bool> {
        Binding {
            group.items.allSatisfy { model.selected.contains($0.node) }
        } set: { selected in
            for item in group.items {
                if selected { model.selected.insert(item.node) } else { model.selected.remove(item.node) }
            }
        }
    }

    var body: some View {
        DisclosureGroup {
            ForEach(group.items.prefix(500), id: \.node) { item in
                HStack {
                    if !isTrash {
                        Toggle(model.path(of: item), isOn: Binding {
                            model.selected.contains(item.node)
                        } set: { selected in
                            if selected { model.selected.insert(item.node) } else { model.selected.remove(item.node) }
                        })
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                    Text(model.path(of: item))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(formatSize(item.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url(of: item.node)]) }
                }
            }
            if group.items.count > 500 {
                Text("\(group.items.count - 500) more items").foregroundStyle(.secondary)
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                if isTrash {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                } else {
                    Toggle(group.category.title, isOn: allSelected).toggleStyle(.checkbox).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.category.title)
                    Text(isTrash ? "Empty the Trash in Finder to get this space back." : group.category.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(formatSize(group.size)).monospacedDigit()
            }
            .padding(.vertical, 2)
        }
    }
}

private struct StaleRow: View {
    @Bindable var model: CleanupModel
    let file: StaleFile

    var body: some View {
        HStack {
            Toggle(file.path, isOn: Binding {
                model.staleSelected.contains(file.node)
            } set: { selected in
                if selected { model.staleSelected.insert(file.node) } else { model.staleSelected.remove(file.node) }
            })
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(filePath: file.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(model.display(URL(filePath: file.path).deletingLastPathComponent().path))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if file.isInICloud {
                Text("iCloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(.separator))
            }
            if let activity = file.lastActivity {
                Text(activity, format: .dateTime.month(.abbreviated).year())
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
            Text(formatSize(file.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file.path)]) }
        }
    }
}

@MainActor final class CleanupWindowController: NSWindowController {
    convenience init(snapshot: ScanSummary, title: String, apply: @escaping CleanupModel.Apply) {
        let model = CleanupModel(snapshot: snapshot, apply: apply)
        let window = NSWindow(contentViewController: NSHostingController(rootView: CleanupView(model: model)))
        window.title = "Clean Up — \(title)"
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 780, height: 580))
        window.setFrameAutosaveName("CleanupWindow")
        self.init(window: window)
    }
}
