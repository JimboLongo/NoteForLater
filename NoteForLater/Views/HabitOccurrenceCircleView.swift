import SwiftUI

/// One tappable circle for a single habit occurrence, cycling through all
/// four `OccurrenceStatus` states on tap (`none -> complete -> missed ->
/// excused -> none`) — the fill color and icon shared verbatim between
/// `HabitsView`'s own Today page and Nightly Review's Habits step, so the
/// two places a habit occurrence gets reviewed can't visually drift apart
/// into two different-looking circles for the same four states.
struct HabitOccurrenceCircleView: View {
    let status: OccurrenceStatus
    var canEdit: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fillColor)
                .frame(width: 36, height: 36)
                .overlay { icon }
        }
        .buttonStyle(.plain)
        .disabled(!canEdit)
        .opacity(canEdit ? 1 : 0.5)
    }

    private var fillColor: Color {
        switch status {
        case .none: return Color.secondary.opacity(0.15)
        case .complete: return .green.opacity(0.6)
        case .missed: return .red.opacity(0.55)
        case .excused: return .gray.opacity(0.4)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .none:
            EmptyView()
        case .complete:
            Image(systemName: "checkmark")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        case .missed:
            Image(systemName: "xmark")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        case .excused:
            Image(systemName: "xmark")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }
}
