import SwiftUI
import AVFoundation

/// Live, continuous barcode scanning for the Kitchen shelf's Pantry —
/// point the camera at item after item, each one looked up on Open Food
/// Facts as it's decoded, then hand the accumulated results to
/// `ReceiptImportView`'s existing review/edit/Add UI via
/// `initialCandidates` rather than duplicating that screen. Uses
/// `AVCaptureMetadataOutput`, the OS's own hardware-accelerated barcode
/// pipeline — not `ReceiptScanService.recognizeBarcodes(in:)`'s
/// Vision-based one-shot detector, which exists for a different case (a
/// single photo containing a barcode) and would be real, avoidable
/// battery cost if run against every live camera frame instead.
struct BarcodeScannerView: View {
    let shelf: Shelf
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ReceiptCandidate] = []
    /// Every barcode string handed to `handleDetectedBarcode`, whether or
    /// not its lookup has resolved yet — this is what turns "the same
    /// physical barcode decoded dozens of times a second while it's held
    /// in frame" into "looked up exactly once." Checked before a lookup
    /// ever starts, not just before a result is added to `candidates`.
    @State private var seenBarcodes: Set<String> = []
    @State private var isShowingReview = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                BarcodeCaptureRepresentable(onDetect: handleDetectedBarcode)
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
            .navigationTitle("Scan Barcodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $isShowingReview) {
                // This view is pushed onto this screen's own
                // NavigationStack, so its own `dismiss()` would only pop
                // back to the live camera feed — `onFinishAdding` here is
                // what actually closes the whole scanner and lands back
                // on the Pantry once Add is tapped.
                ReceiptImportView(shelf: shelf, initialCandidates: candidates, onFinishAdding: { dismiss() })
            }
        }
    }

    /// Fires on the main queue (see `BarcodeCaptureViewController`'s
    /// delegate queue) for every barcode the camera decodes. A new
    /// barcode's lookup runs as its own independent `Task` — concurrent
    /// with any other lookup in flight, never queued behind it, since
    /// each one is entirely independent — while a barcode already seen
    /// this session, whether its own lookup finished or not, is dropped
    /// immediately, before it ever reaches `OpenFoodFactsService`.
    private func handleDetectedBarcode(_ barcode: String) {
        guard !seenBarcodes.contains(barcode) else { return }
        seenBarcodes.insert(barcode)

        Task {
            let info = await OpenFoodFactsService.lookupProductInfo(upc: barcode)
            let candidate: ReceiptCandidate
            if let info {
                candidate = ReceiptCandidate(name: info.name, brand: info.brand, size: info.size, isSelected: true, source: .upcLookup)
            } else {
                // No fallback text to parse the way a receipt line has —
                // a bare barcode has no OCR context at all. Still added,
                // not dropped: the user clearly meant to capture this
                // item, and the placeholder name is editable like any
                // other row before Add.
                candidate = ReceiptCandidate(name: "Unknown item (\(barcode))", brand: nil, size: nil, isSelected: true, source: .upcLookup)
            }
            candidates.append(candidate)
        }
    }
}

/// Thin `UIViewControllerRepresentable` bridge — same division
/// `CameraCaptureView` already draws between SwiftUI and the underlying
/// AVFoundation/UIKit plumbing, just for a live session instead of a
/// single-shot capture.
private struct BarcodeCaptureRepresentable: UIViewControllerRepresentable {
    let onDetect: (String) -> Void

    func makeUIViewController(context: Context) -> BarcodeCaptureViewController {
        let controller = BarcodeCaptureViewController()
        controller.onDetect = onDetect
        return controller
    }

    func updateUIViewController(_ uiViewController: BarcodeCaptureViewController, context: Context) {}
}

private final class BarcodeCaptureViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onDetect: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

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

    /// Unlike `CameraCaptureView`'s `UIImagePickerController`, a raw
    /// `AVCaptureSession` does not prompt for camera access on its own —
    /// creating an `AVCaptureDeviceInput` or starting the session while
    /// authorization is still `.notDetermined` can silently produce
    /// nothing rather than triggering the system prompt. Requesting
    /// explicitly is what makes a first-time user see the permission
    /// dialog instead of a black, unexplained screen. A denied/restricted
    /// result is left as that same black background — Settings is the
    /// only recourse either way, same as this app does nowhere else
    /// builds a custom "please enable camera access" screen.
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

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        // Main queue, not a background one — `onDetect` flows straight
        // into `@State` mutation in `BarcodeScannerView`, and hopping
        // queues just to hop back would add nothing but a race window.
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Only the symbologies groceries actually use — narrowing this,
        // rather than assigning `output.availableMetadataObjectTypes`
        // wholesale, keeps a QR code or other unrelated printed code on
        // the packaging from ever landing in the pantry list as a
        // meaningless "barcode."
        output.metadataObjectTypes = [.ean13, .ean8, .upce, .code128]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject, let value = readable.stringValue else { continue }
            onDetect?(value)
        }
    }

    deinit {
        session.stopRunning()
    }
}
