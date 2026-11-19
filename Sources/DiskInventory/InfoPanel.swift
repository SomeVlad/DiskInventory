import AppKit
import SwiftUI

struct ItemInfo {
    let name: String
    let path: String
    let kind: String
    let allocated: Int64
    let logical: Int64
    let files: Int?
    let created: Date?
    let modified: Date?
    let icon: NSImage
}

private struct InfoView: View {
    let info: ItemInfo?

    var body: some View {
        if let info {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(nsImage: info.icon).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.name).font(.headline).lineLimit(2)
                            Text(info.kind).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    LabeledContent("Where") { Text(info.path).textSelection(.enabled).multilineTextAlignment(.trailing) }
                    LabeledContent("On disk", value: formatSize(info.allocated))
                    LabeledContent("Logical size", value: formatSize(info.logical))
                    if let files = info.files { LabeledContent("Files", value: files.formatted()) }
                    if let created = info.created { LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened)) }
                    if let modified = info.modified { LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened)) }
                }
                Section {
                    HStack {
                        Button("Open") { NSWorkspace.shared.open(URL(filePath: info.path)) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: info.path)]) }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "info.circle", description: Text("Select a file or folder in the tree or on the map"))
        }
    }
}

@MainActor final class InfoPanelController: NSWindowController {
    private let host = NSHostingController(rootView: InfoView(info: nil))

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Info"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: 340, height: 380))
        panel.setFrameAutosaveName("DiskInventory.InfoPanel")
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ info: ItemInfo?) {
        host.rootView = InfoView(info: info)
    }
}
