import AppKit
import SwiftUI
import InventoryCore

enum WindowAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum TreemapPalette: String, CaseIterable, Identifiable {
    case studio, classic, ocean, highContrast

    var id: Self { self }
    var title: String {
        switch self {
        case .studio: "Studio"
        case .classic: "Classic"
        case .ocean: "Ocean"
        case .highContrast: "High Contrast"
        }
    }

    var swatches: [UInt32] {
        switch self {
        case .studio:
            [0x287C9F, 0x5D8653, 0xBA6C41, 0xBEA04A, 0x946879, 0x4D9A91,
             0x6B7DB1, 0xAD6260, 0x667A60, 0x4D8998, 0xAA8459, 0x88965D]
        case .classic:
            [0x315CB5, 0xB8433A, 0x16836C, 0xE3BC42, 0x5186D7, 0xB76322,
             0x357432, 0xC25B88, 0x47ADC2, 0x8A6338, 0x83A63F, 0x8E5368]
        case .ocean:
            [0x204B68, 0x307E9C, 0x2E8B7B, 0x9BC7C1, 0x536979, 0x4CA5C7,
             0x789E8A, 0x697DA4, 0x3B6564, 0xA1B0C0, 0x8BA58B, 0x74AC9F]
        case .highContrast:
            [0x004B87, 0xE49800, 0x007052, 0xCE5540, 0x82B9ED, 0x6B452A,
             0x87A500, 0x51254E, 0x1D807E, 0xD291B2, 0x636B73, 0xCBCC57]
        }
    }

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1
        )
    }

    static func foreground(on color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let linear: (CGFloat) -> CGFloat = { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.179 ? .black : .white
    }
}

struct MapAppearance: Equatable {
    var labels = true
    var folderBorders = false
}

@MainActor enum Settings {
    static var store = UserDefaults.standard
    static var layoutNamespace = "DiskInventory"

    static func layoutName(_ name: String) -> String { "\(layoutNamespace).\(name)" }

    static func bool(_ key: String, default fallback: Bool = false) -> Bool {
        store.object(forKey: key) as? Bool ?? fallback
    }

    static var appearance: WindowAppearance {
        store.string(forKey: "appearance").flatMap(WindowAppearance.init(rawValue:)) ?? .system
    }

    static var treemapPalette: TreemapPalette {
        store.string(forKey: "treemapPalette").flatMap(TreemapPalette.init(rawValue:)) ?? .studio
    }

    static var mapAppearance: MapAppearance {
        MapAppearance(labels: bool("treemapLabels", default: true), folderBorders: bool("treemapFolderBorders"))
    }

    static var options: ViewOptions {
        var options = ViewOptions()
        options.mode = bool("physical", default: true) ? .allocated : .logical
        options.packages = bool("packages")
        options.free = bool("free")
        options.other = bool("other")
        return options
    }
}

struct PreferencesView: View {
    enum Page: String, CaseIterable {
        case appearance, scanning, behavior
    }

    @AppStorage("preferencesPage") private var page = Page.appearance
    @AppStorage("appearance") private var appearance = WindowAppearance.system
    @AppStorage("treemapPalette") private var palette = TreemapPalette.studio
    @AppStorage("treemapLabels") private var labels = true
    @AppStorage("treemapFolderBorders") private var borders = false
    @AppStorage("physical") private var physical = true
    @AppStorage("ignoreCreator") private var ignoreCreator = true
    @AppStorage("packages") private var packages = false
    @AppStorage("free") private var free = false
    @AppStorage("other") private var other = false
    @AppStorage("animate") private var animate = true
    @AppStorage("shareColors") private var shareColors = true
    @AppStorage("vertical") private var vertical = false
    @AppStorage("smallFont") private var smallFont = false
    @AppStorage("confirmTrash") private var confirmTrash = true
    @AppStorage("syncFinder") private var syncFinder = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings page", selection: $page) {
                Label("Appearance", systemImage: "paintpalette").tag(Page.appearance)
                Label("Scanning", systemImage: "internaldrive").tag(Page.scanning)
                Label("Behavior", systemImage: "switch.2").tag(Page.behavior)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 390)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch page {
                case .appearance: appearancePane
                case .scanning: scanningPane
                case .behavior: behaviorPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 682, height: 582)
    }

    private var appearancePane: some View {
        Form {
            Section {
                Picker("Window appearance", selection: $appearance) {
                    ForEach(WindowAppearance.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Treemap") {
                VStack(alignment: .leading, spacing: 12) {
                    TreemapPreview(palette: palette, labels: labels, borders: borders)
                    HStack(spacing: 8) {
                        ForEach(TreemapPalette.allCases) { option in
                            paletteButton(option)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Treemap color palette")
                }
                Toggle("Show file names on the map", isOn: $labels)
                Toggle("Outline folders on the map", isOn: $borders)
            }
            Section("Layout") {
                Picker("Tree and map", selection: $vertical) {
                    Text("Side by side").tag(false)
                    Text("Stacked").tag(true)
                }
                Toggle("Use compact text in the file tree", isOn: $smallFont)
            }
        }
        .formStyle(.grouped)
    }

    private var scanningPane: some View {
        Form {
            Section("File sizes") {
                Picker("Measure by", selection: $physical) {
                    Text("Size on disk").tag(true)
                    Text("Logical size").tag(false)
                }
                Text("Size on disk reports allocated storage. Logical size reports the length of the file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("File kinds") {
                Toggle("Show package contents", isOn: $packages)
                Toggle("Use Finder’s detailed kind names", isOn: Binding(
                    get: { !ignoreCreator }, set: { ignoreCreator = !$0 }
                ))
                Text("Finder names are shared by matching file types. Changing this setting updates open scans.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Volume maps") {
                Toggle("Show free space", isOn: $free)
                Toggle("Show other space", isOn: $other)
            }
        }
        .formStyle(.grouped)
    }

    private var behaviorPane: some View {
        Form {
            Section("Navigation") {
                Toggle("Animate treemap zoom", isOn: $animate)
                Toggle("Share file-kind colors across windows", isOn: $shareColors)
            }
            Section("File actions") {
                Toggle("Reveal the selected item in Finder", isOn: $syncFinder)
                Toggle("Confirm before moving items to Trash", isOn: $confirmTrash)
            }
            Section("Finder") {
                Text("Drop a folder onto the app icon, or use Services → Scan with Disk Inventory from Finder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func paletteButton(_ option: TreemapPalette) -> some View {
        Button {
            palette = option
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(Array(option.swatches.prefix(5).enumerated()), id: \.offset) { _, rgb in
                        Rectangle().fill(Color(nsColor: TreemapPalette.color(rgb)))
                    }
                }
                .frame(height: 12)
                .clipShape(.rect(cornerRadius: 3))
                HStack(spacing: 4) {
                    Text(option.title)
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                    if palette == option {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .lineLimit(1)
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(palette == option ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
                        in: .rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(palette == option ? Color.accentColor : Color(nsColor: .separatorColor))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(palette == option ? .isSelected : [])
    }
}

private struct TreemapPreview: View {
    let palette: TreemapPalette
    let labels: Bool
    let borders: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                tile(0, "Archives")
                    .frame(width: (geometry.size.width - 8) * 0.43)
                VStack(spacing: 2) {
                    tile(1, "Audio")
                    HStack(spacing: 2) {
                        tile(2, "Video")
                        tile(3, "Images")
                    }
                }
                .overlay {
                    if borders {
                        Rectangle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                    }
                }
                VStack(spacing: 2) {
                    tile(4, "Docs")
                    tile(5, "")
                    tile(6, "")
                }
                .frame(width: (geometry.size.width - 8) * 0.15)
            }
            .padding(2)
        }
        .frame(height: 116)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(.rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Treemap preview")
    }

    private func tile(_ index: Int, _ title: String) -> some View {
        let color = TreemapPalette.color(palette.swatches[index])
        return Rectangle()
            .fill(Color(nsColor: color))
            .overlay(alignment: .topLeading) {
                if labels, !title.isEmpty {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(nsColor: TreemapPalette.foreground(on: color)))
                        .lineLimit(1)
                        .padding(6)
                }
            }
    }
}

@MainActor final class KindColors {
    static let shared = KindColors()
    private var assigned: [String: Int] = [:]

    func colors(for snapshot: ScanSummary, totals: [KindTotal], palette: TreemapPalette) -> [NSColor] {
        let swatches = palette.swatches
        for total in totals where assigned.count < swatches.count {
            let key = snapshot.kinds[total.kind].identifier
            if assigned[key] == nil { assigned[key] = assigned.count }
        }
        return snapshot.kinds.map {
            guard let index = assigned[$0.identifier], swatches.indices.contains(index) else {
                return TreemapPalette.color(0x818993)
            }
            return TreemapPalette.color(swatches[index])
        }
    }
}
