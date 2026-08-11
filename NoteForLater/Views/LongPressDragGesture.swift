import SwiftUI
import UIKit

/// A UIKit-backed hold-then-drag gesture, bridged into SwiftUI via
/// `UIGestureRecognizerRepresentable` (iOS 18+).
///
/// Every pure-SwiftUI `Gesture` composition tried for the timeline's
/// drag-to-move interaction — a bare `DragGesture`, `LongPressGesture
/// .sequenced(before: DragGesture(minimumDistance: 0))`, and splitting
/// arm/track into two independently-masked gestures — either fought
/// `ScrollView`'s own pan (blocking scroll outright) or broke continuity
/// (needing the finger lifted and pressed again between the hold and the
/// drag). This is a known, documented SwiftUI limitation, not a threshold
/// to keep tuning: SwiftUI's `Gesture` protocol has no way to explicitly
/// tell the system "let my gesture and the ScrollView's recognize at the
/// same time" — but real `UIGestureRecognizerDelegate` does, via
/// `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` — the actual
/// mechanism iOS provides for exactly this conflict.
///
/// This wraps a real `UILongPressGestureRecognizer`: `.began` fires once
/// `minimumDuration` elapses (the "hold"), and it keeps delivering
/// `.changed` events with live location for the *same* touch for as long
/// as it stays down and moves (the "drag") — no gesture hand-off, so no
/// continuity problem. The delegate unconditionally returns `true` from
/// `shouldRecognizeSimultaneouslyWith`, so the ScrollView's pan recognizer
/// is free to *also* recognize a touch that doesn't satisfy this one (a
/// quick scroll swipe fails `minimumDuration` and falls through to
/// scrolling normally).
struct LongPressDragGesture: UIGestureRecognizerRepresentable {
    var minimumDuration: TimeInterval
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = minimumDuration
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.minimumPressDuration = minimumDuration
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        // `recognizer.location(in: recognizer.view)` is raw UIKit and can
        // land in the wrong coordinate space once this sits inside a
        // ScrollView — `context.converter` is the framework's own bridge
        // back to the coordinate space of the SwiftUI view this gesture is
        // actually attached to, which is what all the offset math
        // elsewhere in this file assumes.
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began:
            onBegan(location)
        case .changed:
            onChanged(location)
        case .ended:
            onEnded(location)
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
