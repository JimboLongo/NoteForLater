import SwiftUI

/// Identifies which tag's location is being edited — plain String isn't
/// Identifiable, and this is shared by any tag-editing surface.
struct TagLocationTarget: Identifiable {
    let name: String
    var id: String { name }
}

struct TagChip: View {
    let text: String
    let hasLocation: Bool
    let onTapLocation: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTapLocation) {
                Image(systemName: hasLocation ? "mappin.circle.fill" : "mappin.circle")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            Text(text)
                .font(.caption)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.15))
        .clipShape(Capsule())
    }
}
