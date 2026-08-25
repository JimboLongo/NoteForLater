import SwiftUI
import AVFoundation
import CoreImage

/// Live, continuous receipt scanning — point the camera down a receipt
/// and every UPC-bearing line gets OCR'd, extracted, and looked up as it
/// scrolls past, instead of taking one photo and hoping it's in focus.
/// Shares `BarcodeScannerView`'s session/preview/permission scaffolding in
/// spirit, but not its actual capture output: `AVCaptureMetadataOutput`
/// (barcode-only) exposes no image frames at all, so this needs
/// `AVCaptureVideoDataOutput` instead, feeding real frames to
/// `ReceiptScanService.recognizeTextLines(in:orientation:)` — the same
/// Vision text recognizer the single-photo flow already uses, just run
/// continuously, and kept to the bounding-box-carrying variant so the
/// live overlay boxes below have something to draw.
///
/// Unlike the barcode scanner, this genuinely costs real, unavoidable
/// per-frame work: there's no hardware-accelerated OCR pipeline the way
/// there is for barcodes, so every processed frame is a real Vision
/// `.accurate` text request. Throttled by skipping any new frame while a
/// previous OCR pass is still in flight (`isProcessingFrame`) — adapts to
/// whatever the device can actually sustain, rather than guessing a fixed
/// interval.
struct ReceiptOCRScannerView: View {
    let shelf: Shelf
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var scanService = ReceiptScanService()
    @State private var candidates: [ReceiptCandidate] = []
    /// Every UPC any OCR pass has ever extracted, and what's known about
    /// it — this is the "look up exactly once" cache (requirement: don't
    /// re-query the same code), and it persists across frames on
    /// purpose, unlike `visibleBoxes` below. A box's fill color reads
    /// from here.
    @State private var lookupCache: [String: UPCLookupState] = [:]
    /// What the *current* frame actually showed — replaced wholesale on
    /// every completed OCR pass, not accumulated, so a box for a line
    /// that's since scrolled out of frame disappears on the next pass
    /// instead of lingering forever. `lookupCache` is what remembers a
    /// UPC's result across that replacement.
    @State private var visibleBoxes: [(upc: String, boundingBox: CGRect)] = []
    @State private var isProcessingFrame = false
    @State private var isShowingReview = false
    @State private var isShowingPhotoImporter = false
    @State private var isShowingUnmatchedEditor = false
    /// Every UPC in the order it was *first* extracted by OCR — since a
    /// receipt is naturally scanned top to bottom in one continuous pass,
    /// this is a reliable stand-in for physical receipt order without
    /// needing to reconstruct real on-page position across frames.
    /// Appended to exactly once per UPC, in `handleFrame`'s `.none` case,
    /// regardless of whether that UPC goes on to resolve or not — this is
    /// what lets `UnmatchedUPCsEditorView` show matched and unmatched
    /// lines interleaved the way they actually appeared, instead of two
    /// disconnected lists.
    @State private var upcOrder: [String] = []
    /// The resolved product info behind every `.found` entry in
    /// `lookupCache`, keyed by UPC — `ReceiptCandidate` itself doesn't
    /// retain the UPC it came from, so this is what lets the combined
    /// review list show an already-matched line's name/brand/size (and
    /// what `attemptAutoPopulate`'s duplicate check in
    /// `UnmatchedUPCsEditorView` compares a corrected UPC against).
    @State private var foundInfo: [String: OpenFoodFactsService.ProductInfo] = [:]

    /// What `ReceiptOCRCaptureRepresentable` actually draws — each
    /// currently-visible box paired with whatever `lookupCache` currently
    /// knows about its UPC. A box whose lookup hasn't resolved yet reads
    /// as `.pending` here even though it's already showing on screen —
    /// deliberately drawn immediately in gray rather than waiting for the
    /// network round-trip, so panning past a line before its lookup
    /// finishes doesn't look like the scanner missed it entirely.
    private var overlayEntries: [(boundingBox: CGRect, state: UPCLookupState)] {
        visibleBoxes.map { box in
            (box.boundingBox, lookupCache[box.upc] ?? .pending)
        }
    }

    /// Every UPC seen this session that never became a real candidate —
    /// genuinely not in Open Food Facts' catalog, still `.retryable`, or
    /// simply never got a turn before "Done Scanning" was tapped. Offered
    /// to `UnmatchedUPCsEditorView` for manual entry rather than just
    /// being dropped silently. Ordered via `upcOrder`, not just filtered
    /// out of `lookupCache` (a `Dictionary`, with no meaningful order of
    /// its own) — only actually matters for "is there anything to
    /// review" here, but keeps this consistent with `upcOrder` being the
    /// one source of truth for order everywhere else it's used.
    private var unmatchedUPCs: [String] {
        upcOrder.filter { upc in
            if case .found = lookupCache[upc] { return false }
            return true
        }
    }

    /// Whether any box currently on screen came back not-found — a
    /// stronger hint that OCR misread a digit than that the product is
    /// genuinely absent from Open Food Facts' catalog: real grocery UPCs
    /// resolve the large majority of the time (confirmed by
    /// `OpenFoodFactsService`'s own diag logging during an earlier
    /// investigation, where several of the "not found" results turned
    /// out to be truncated digit runs, not real answers). Surfaced as a
    /// live nudge to reposition the camera over that specific line —
    /// re-reading the same physical barcode from a slightly different
    /// angle is what actually produces a different (hopefully correct)
    /// OCR extraction, not anything this code can retry on its own.
    private var hasVisibleNotFoundBox: Bool {
        visibleBoxes.contains { box in
            if case .notFound = lookupCache[box.upc] { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ReceiptOCRCaptureRepresentable(onFrame: handleFrame, overlayEntries: overlayEntries)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    if hasVisibleNotFoundBox {
                        Text("Red box: no match found. Often a misread digit — try repositioning the camera over it.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.red.opacity(0.85), in: Capsule())
                    }
                    Text("\(candidates.count) scanned")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                    Button("Done Scanning") {
                        if unmatchedUPCs.isEmpty {
                            isShowingReview = true
                        } else {
                            isShowingUnmatchedEditor = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    // Not just `candidates.isEmpty` — a receipt where
                    // every line so far is unmatched (nothing resolved
                    // yet) still has UPCs worth reviewing manually, and
                    // gating on matches alone would trap the user with no
                    // way to ever reach that editor.
                    .disabled(candidates.isEmpty && unmatchedUPCs.isEmpty)
                }
                .padding(.bottom, 32)
            }
            .navigationTitle("Scan Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Fallback for a receipt too crumpled/dark for live
                    // OCR to track reliably — the original single-photo
                    // flow, unchanged, still one tap away rather than
                    // removed.
                    Menu {
                        Button("Import from Photo") {
                            isShowingPhotoImporter = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(isPresented: $isShowingReview) {
                // Pushed onto this screen's own NavigationStack, so its
                // own `dismiss()` would only pop back to the live camera
                // feed — `onFinishAdding` is what actually closes the
                // whole scanner and lands back on the Pantry once Add is
                // tapped. Same reasoning as `BarcodeScannerView`.
                ReceiptImportView(shelf: shelf, initialCandidates: candidates, onFinishAdding: { dismiss() })
            }
            .fullScreenCover(isPresented: $isShowingPhotoImporter) {
                ReceiptImportView(shelf: shelf)
            }
            .sheet(isPresented: $isShowingUnmatchedEditor) {
                // Every UPC seen this session, not just the unmatched
                // ones — showing matched lines alongside unmatched ones
                // in their original scan order is what makes it obvious
                // which specific lines were missed, rather than a bare
                // list of failures with no receipt context around them.
                UnmatchedUPCsEditorView(orderedUPCs: upcOrder, foundInfo: foundInfo) { newCandidates in
                    // Only ever *new* candidates from originally-unmatched
                    // rows — an originally-matched row's own candidate is
                    // already sitting in `candidates` from `handleFrame`,
                    // so re-adding it here would duplicate it.
                    candidates.append(contentsOf: newCandidates)
                    isShowingReview = true
                }
            }
        }
    }

    /// Fires on the main queue (see `ReceiptOCRCaptureViewController`'s
    /// delegate queue) for every frame the camera delivers, gated by
    /// `isProcessingFrame` so at most one OCR pass ever runs at a time.
    /// `.right` orientation — see `ReceiptScanService.recognizeTextLines`'s
    /// own doc comment for why a live back-camera-in-portrait frame needs
    /// this spelled out explicitly rather than defaulting to `.up`.
    private func handleFrame(_ image: UIImage) {
        guard !isProcessingFrame else { return }
        isProcessingFrame = true

        Task {
            defer { isProcessingFrame = false }
            let lines = await scanService.recognizeTextLines(in: image, orientation: .right)

            var newVisibleBoxes: [(upc: String, boundingBox: CGRect)] = []
            var newUPCs: [String] = []
            for line in lines {
                guard let upc = ReceiptLineParser.upc(in: line.text) else { continue }
                newVisibleBoxes.append((upc, line.boundingBox))
                switch lookupCache[upc] {
                case .none:
                    // First time this UPC has ever been seen — recorded
                    // here, unconditionally, regardless of which branch
                    // below it then takes. See `upcOrder`'s own doc
                    // comment for why this is the one place that's
                    // guaranteed to run exactly once per UPC.
                    upcOrder.append(upc)
                    // Checked synchronously, outside the concurrent/
                    // rate-limited path below — a banked UPC resolves
                    // for free and never needs to touch the network or
                    // wait on `RequestRateLimiter` at all. Kept here
                    // rather than inside `lookupConcurrently`'s closure
                    // because that closure is `@Sendable` and
                    // `ModelContext` isn't; a plain synchronous check in
                    // this main-actor loop sidesteps the problem
                    // entirely instead of needing a workaround for it.
                    if let banked = UPCLookupService.checkUPCBank(upc: upc, in: modelContext) {
                        lookupCache[upc] = .found
                        foundInfo[upc] = banked
                        candidates.append(ReceiptCandidate(name: banked.name, brand: banked.brand, size: banked.size, isSelected: true, source: .upcLookup))
                    } else {
                        newUPCs.append(upc)
                    }
                case .retryable(let lastAttempt) where Date().timeIntervalSince(lastAttempt) > Self.retryBackoff:
                    // Eligible again — enough time has passed that Open
                    // Food Facts' own rate-limit window has likely
                    // cleared. Checked against `lastAttempt`, not just
                    // "was it ever `.retryable`," so a UPC still on
                    // screen doesn't get re-fired on every single frame
                    // while the limiter is still actively backing off.
                    newUPCs.append(upc)
                default:
                    break
                }
            }
            // Replaced wholesale, not appended — see `visibleBoxes`'s own
            // doc comment for why that's what makes a stale box actually
            // disappear once its line scrolls out of frame.
            visibleBoxes = newVisibleBoxes

            guard !newUPCs.isEmpty else { return }
            for upc in newUPCs {
                lookupCache[upc] = .pending
            }

            // Capped at `maxConcurrentLookups`, not one Task per UPC — a
            // single receipt frame with a dozen-plus lines used to fire
            // that many concurrent Open Food Facts requests at once,
            // which is exactly what pushed their API into rate-limiting
            // the whole burst with HTTP 429 (found via the diag logging
            // `OpenFoodFactsService.lookupProductInfo` added for that
            // investigation). A handful in flight at a time still
            // overlaps lookups enough to feel instant without tripping
            // the limiter.
            let results = await Self.lookupConcurrently(newUPCs, maxConcurrent: Self.maxConcurrentLookups) { upc in
                (upc, await OpenFoodFactsService.lookupProductInfoDetailed(upc: upc))
            }
            for (upc, outcome) in results {
                switch outcome {
                case .found(let info):
                    lookupCache[upc] = .found
                    foundInfo[upc] = info
                    candidates.append(ReceiptCandidate(name: info.name, brand: info.brand, size: info.size, isSelected: true, source: .upcLookup))
                case .notFound:
                    lookupCache[upc] = .notFound
                case .rateLimited:
                    lookupCache[upc] = .retryable(lastAttempt: .now)
                }
            }
        }
    }

    /// How long a `.retryable` UPC sits out before `handleFrame` will
    /// fire it again — long enough that a rate-limited burst has a real
    /// chance to clear, short enough that a still-visible line resolves
    /// within a couple of retry windows rather than needing the user to
    /// hold the camera on it indefinitely.
    private static let retryBackoff: TimeInterval = 3

    /// The middle of Open Food Facts' own suggested range for a
    /// well-behaved anonymous client — enough overlap to still feel
    /// instant, without reproducing the 429 cascade a full, unbounded
    /// burst caused.
    private static let maxConcurrentLookups = 4

    /// Runs `operation` over `items` with at most `maxConcurrent` running
    /// at once, returning results in `items`' own order rather than
    /// completion order.
    ///
    /// Deliberately not a `DispatchSemaphore` around the loop below —
    /// `semaphore.wait()` blocks whatever thread is running this `Task`,
    /// and Swift Concurrency's cooperative thread pool has a fixed, small
    /// number of threads with no guarantee one is free to keep other work
    /// moving while this one sits blocked; that's a real deadlock risk,
    /// not just a style preference. This gets the same cap with no
    /// blocking at all: only `maxConcurrent` child tasks are ever alive
    /// in the group at once, and the next one starts the instant any one
    /// finishes.
    private static func lookupConcurrently<Result: Sendable>(
        _ items: [String],
        maxConcurrent: Int,
        operation: @escaping @Sendable (String) async -> Result
    ) async -> [Result] {
        await withTaskGroup(of: (Int, Result).self) { group in
            var nextIndex = 0
            func startNext() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                let item = items[index]
                nextIndex += 1
                group.addTask { (index, await operation(item)) }
            }
            for _ in 0..<min(maxConcurrent, items.count) {
                startNext()
            }
            var indexed: [(Int, Result)] = []
            for await entry in group {
                indexed.append(entry)
                startNext()
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

/// What's currently known about one scanned UPC — drives both
/// `ReceiptOCRScannerView`'s own bookkeeping and the overlay box's color.
enum UPCLookupState {
    case pending
    case found
    case notFound
    /// Hit Open Food Facts' rate limiter (HTTP 429) rather than a real
    /// "not a product" answer — kept distinct from `.notFound` so it
    /// stays eligible for another attempt once the limiter backs off,
    /// instead of being written off permanently for the rest of the
    /// session. `lastAttempt` is what lets `handleFrame` wait a beat
    /// before trying the same UPC again rather than re-firing it on
    /// every subsequent frame while still rate-limited.
    case retryable(lastAttempt: Date)

    var boxColor: UIColor {
        switch self {
        case .pending: return .lightGray
        // An explicit lime, not `.green`/`.systemGreen` — closer to what
        // "lime green" actually names than either of those reads as.
        case .found: return UIColor(red: 0.6, green: 1.0, blue: 0.2, alpha: 1)
        case .notFound: return .red
        case .retryable: return .orange
        }
    }
}

/// Thin `UIViewControllerRepresentable` bridge — same division
/// `CameraCaptureView`/`BarcodeScannerView` already draw between SwiftUI
/// and the underlying AVFoundation/UIKit plumbing.
private struct ReceiptOCRCaptureRepresentable: UIViewControllerRepresentable {
    let onFrame: (UIImage) -> Void
    let overlayEntries: [(boundingBox: CGRect, state: UPCLookupState)]

    func makeUIViewController(context: Context) -> ReceiptOCRCaptureViewController {
        let controller = ReceiptOCRCaptureViewController()
        controller.onFrame = onFrame
        return controller
    }

    func updateUIViewController(_ uiViewController: ReceiptOCRCaptureViewController, context: Context) {
        uiViewController.updateOverlays(overlayEntries)
    }
}

private final class ReceiptOCRCaptureViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((UIImage) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let frameQueue = DispatchQueue(label: "com.jimbo.NoteForLater.receipt-ocr-frames")
    /// Reused across every frame — creating a `CIContext` is a real,
    /// non-trivial cost, and this delegate method fires many times a
    /// second.
    private let ciContext = CIContext()
    /// Every overlay box currently on screen — cleared and fully redrawn
    /// each time `updateOverlays` runs (see its own doc comment) rather
    /// than diffed against the previous set, since the sets involved are
    /// small (a handful of lines per frame at most) and a full redraw is
    /// simpler than tracking per-box identity across frames.
    private var overlayLayers: [CAShapeLayer] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestAccessThenConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    /// See `BarcodeCaptureViewController.requestAccessThenConfigure`'s own
    /// doc comment — same reasoning, same shape, duplicated rather than
    /// shared because these two view controllers otherwise have no common
    /// base and factoring one out for a single method wasn't worth the
    /// abstraction.
    private func requestAccessThenConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.configureSession() }
            }
        default:
            break
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        // A dedicated background queue, not main — unlike the barcode
        // scanner's lightweight metadata callback, this delegate method
        // does real work (pixel buffer -> CGImage) on every call, and
        // that shouldn't compete with SwiftUI's own main-thread work.
        // `onFrame` itself hops back to main before touching any
        // `@State`, further down in `captureOutput`.
        output.setSampleBufferDelegate(self, queue: frameQueue)

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(image)
        }
    }

    /// Redraws the overlay from scratch on every call — old boxes are
    /// removed first, so one that's no longer in `entries` (its line
    /// scrolled out of frame, per `ReceiptOCRScannerView.visibleBoxes`'s
    /// own doc comment) simply isn't recreated, rather than needing to be
    /// explicitly cleaned up.
    ///
    /// `layerRectConverted(fromMetadataOutputRect:)` expects its input in
    /// `AVCaptureMetadataOutput`'s own coordinate space: normalized,
    /// **top-left origin, on the raw/unrotated buffer** — that's what
    /// makes it correctly account for `.resizeAspectFill`'s cropping.
    /// `entry.boundingBox` is Vision's own **bottom-left origin** box,
    /// and — because `handleFrame` hands Vision's request an explicit
    /// `.right` orientation — Vision reports it in the coordinate space
    /// of the *already-rotated, upright* image, not the raw landscape
    /// buffer. Both of those differ from what `layerRectConverted`
    /// wants, so `rawBufferRect(for:)` below undoes both before handing
    /// off to it — skipping either step is what previously put boxes at
    /// 90° from where they belonged.
    func updateOverlays(_ entries: [(boundingBox: CGRect, state: UPCLookupState)]) {
        overlayLayers.forEach { $0.removeFromSuperlayer() }
        guard let previewLayer else {
            overlayLayers = []
            return
        }
        overlayLayers = entries.map { entry in
            let metadataRect = Self.rawBufferRect(for: entry.boundingBox)
            let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
            let layer = CAShapeLayer()
            layer.path = UIBezierPath(rect: rect).cgPath
            layer.strokeColor = entry.state.boxColor.cgColor
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 3
            previewLayer.addSublayer(layer)
            return layer
        }
    }

    /// Maps a Vision `boundingBox` — bottom-left origin, normalized to
    /// the `.right`-corrected upright image — back to
    /// `AVCaptureMetadataOutput`'s own convention: top-left origin,
    /// normalized to the raw, unrotated buffer.
    ///
    /// Two independent corrections, composed:
    /// - Bottom-left → top-left origin is an ordinary Y-flip:
    ///   `y' = 1 - y - height`.
    /// - Undoing the `.right` rotation (raw buffer needs a 90° clockwise
    ///   turn to become the upright image Vision actually measured
    ///   against) swaps width/height and remaps each axis through the
    ///   other: `x' = 1 - maxY`, `y' = 1 - maxX`. Composed with the
    ///   Y-flip above, the two collapse to the single formula below —
    ///   there's no separate intermediate rect to build.
    private static func rawBufferRect(for boundingBox: CGRect) -> CGRect {
        CGRect(
            x: 1 - boundingBox.maxY,
            y: 1 - boundingBox.maxX,
            width: boundingBox.height,
            height: boundingBox.width
        )
    }

    deinit {
        session.stopRunning()
    }
}
