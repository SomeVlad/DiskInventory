import Charts
import SwiftUI
import InventoryCore

struct VolumeBreakdown: View {
    struct Part: Identifiable {
        let name: String
        let bytes: Int64
        let color: Color
        var id: String { name }
    }

    let volume: VolumeUsage
    let scanned: Int64

    private var parts: [Part] {
        let used = max(0, volume.capacity - volume.free)
        let known = min(scanned, used)
        return [
            Part(name: "Scanned", bytes: known, color: .accentColor),
            Part(name: "Other", bytes: used - known, color: .secondary.opacity(0.57)),
            Part(name: "Free", bytes: volume.free, color: .secondary.opacity(0.19))
        ]
    }

    var body: some View {
        HStack(spacing: 10) {
            Chart(parts) { part in
                SectorMark(angle: .value("Bytes", part.bytes), innerRadius: .ratio(0.68))
                    .foregroundStyle(part.color)
                    .accessibilityLabel(part.name)
                    .accessibilityValue(formatSize(part.bytes))
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(parts) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.color).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(part.name)
                        Spacer()
                        Text(formatSize(part.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}
