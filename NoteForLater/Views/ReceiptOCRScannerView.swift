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

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ReceiptOCRCaptureRepresentable(onFrame: handleFrame, overlayEntries: overlayEntries)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("\(candidates.count) scanned")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                    Button("Done Scanning") {
                        isShowingReview = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(candidates.isEmpty)
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
                if lookupCache[upc] == nil {
                    newUPCs.append(upc)
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

            // Concurrent, not queued behind each other — a single receipt
            // frame can show several UPC-bearing lines at once, same
            // convention the original photo-based receipt flow already
            // established for a whole receipt's worth of lines together.
            await withTaskGroup(of: (String, OpenFoodFactsService.ProductInfo?).self) { group in
                for upc in newUPCs {
                    group.addTask { (upc, await OpenFoodFactsService.lookupProductInfo(upc: upc)) }
                }
                for await (upc, info) in group {
                    if let info {
                        lookupCache[upc] = .found
                        candidates.append(ReceiptCandidate(name: info.name, brand: info.brand, size: info.size, isSelected: true, source: .upcLookup))
                    } else {
                        lookupCache[upc] = .notFound
                    }
                }
            }
        }
    }
}

/// What's currently known about one scanned UPC — drives both
/// `ReceiptOCRScannerView`'s own bookkeeping and the overlay box's color.
enum UPCLookupState {
    case pending
    case found
    case notFound

    var boxColor: UIColor {
        switch self {
        case .pending: return .lightGray
        // An explicit lime, not `.green`/`.systemGreen` — closer to what
        // "lime green" actually names than either of those reads as.
        case .found: return UIColor(red: 0.6, green: 1.0, blue: 0.2, alpha: 1)
        case .notFound: return .red
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
    /// explicitly cleaned up. `layerRectConverted(fromMetadataOutputRect:)`
    /// is what turns Vision's normalized, bottom-left-origin box into the
    /// correct on-screen rect for this exact preview layer, accounting
    /// for `.resizeAspectFill`'s own cropping — the same conversion
    /// AVFoundation's own metadata-object APIs use, which is why Vision's
    /// coordinate convention was designed to match it in the first place.
    func updateOverlays(_ entries: [(boundingBox: CGRect, state: UPCLookupState)]) {
        overlayLayers.forEach { $0.removeFromSuperlayer() }
        guard let previewLayer else {
            overlayLayers = []
            return
        }
        overlayLayers = entries.map { entry in
            let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: entry.boundingBox)
            let layer = CAShapeLayer()
            layer.path = UIBezierPath(rect: rect).cgPath
            layer.strokeColor = entry.state.boxColor.cgColor
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 3
            previewLayer.addSublayer(layer)
            return layer
        }
    }

    deinit {
        session.stopRunning()
    }
}
