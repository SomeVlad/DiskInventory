import SwiftUI
import InventoryCore

struct VolumeBreakdown: View {
    struct Part: Identifiable {
        let name: String
        let bytes: Int64
        let opacity: Double
        var id: String { name }
    }

    let volume: VolumeUsage
    let scanned: Int64

    private var parts: [Part] {
        let used = max(0, volume.capacity - volume.free)
        let known = min(scanned, used)
        return [
            Part(name: "Scanned", bytes: known, opacity: 0.55),
            Part(name: "Other", bytes: used - known, opacity: 0.25),
            Part(name: "Free", bytes: volume.free, opacity: 0.08)
        ]
    }

    var body: some View {
        let total = max(1, parts.reduce(Int64(0)) { $0 + $1.bytes })
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(parts) { part in
                        Rectangle()
                            .fill(Color.primary.opacity(part.opacity))
                            .frame(width: max(0, geometry.size.width * CGFloat(part.bytes) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(.rect(cornerRadius: 4))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Volume usage")
            .accessibilityValue(parts.map { "\($0.name) \(formatSize($0.bytes))" }.joined(separator: ", "))
            ForEach(parts) { part in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(part.opacity)).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(part.name)
                    Spacer()
                    Text(formatSize(part.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
