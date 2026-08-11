import SwiftUI
import UIKit

/// A UIKit-backed pan gesture, bridged into SwiftUI the same way
/// `LongPressDragGesture` is (see that file for the full rationale) — a
/// plain SwiftUI `DragGesture` attached to a row inside a `ScrollView`
/// claims the touch the moment it starts moving in *any* direction,
/// blocking the ScrollView's own vertical pan even for a swipe that's
/// purely horizontal. Wrapping a real `UIPanGestureRecognizer`, whose
/// delegate unconditionally allows simultaneous recognition, lets both
/// recognizers track the same touch at once: the ScrollView scrolls
/// normally for vertical movement, and callers of this gesture simply
/// ignore `onChanged` calls whose translation isn't horizontally
/// dominant, so a swipe-to-delete row and a scrolling calendar coexist
/// without either blocking the other.
struct PanSwipeGesture: UIGestureRecognizerRepresentable {
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
