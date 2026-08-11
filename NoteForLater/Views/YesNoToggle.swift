import SwiftUI

/// A Yes/No pair that starts with neither pressed. Unlike a plain
/// `Toggle`, "off" isn't a value this defaults to on its own — "off" is
/// itself a real, meaningful answer (e.g. "no due date"), so leaving a
/// Toggle unswitched would silently pick that answer instead of asking
/// for it. This stays unanswered (`answer == nil`) until the user
/// actually presses Yes or No.
struct YesNoToggle: View {
    let title: String
    @Binding var answer: Bool?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 8) {
                pill("Yes", isSelected: answer == true) { answer = answer == true ? nil : true }
                pill("No", isSelected: answer == false) { answer = answer == false ? nil : false }
            }
        }
    }

    private func pill(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 64)
                .padding(.vertical, 9)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
