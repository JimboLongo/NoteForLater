import Vision
import UIKit
import Observation

/// Runs Vision's text recognition over a receipt photo and hands back the
/// raw recognized lines — `ReceiptLineParser` is what turns those into
/// candidate item names, kept separate so the parsing logic is testable
/// without needing an actual image or the Vision framework.
@Observable
final class ReceiptScanService {
    var isProcessing = false
    var errorMessage: String?

    func recognizeLines(in image: UIImage) async -> [String] {
        await recognizeTextLines(in: image).map(\.text)
    }

    /// One recognized line of text plus where it sits in the image —
    /// `boundingBox` is Vision's own normalized, bottom-left-origin
    /// coordinate space (0...1 on both axes). That's deliberately the
    /// same convention `AVCaptureVideoPreviewLayer
    /// .layerRectConverted(fromMetadataOutputRect:)` expects, so
    /// `ReceiptOCRScannerView` can hand this straight through to draw a
    /// correctly-placed overlay box with no extra conversion math of its
    /// own — it still has to get `orientation` right first, see below.
    struct RecognizedTextLine {
        let text: String
        let boundingBox: CGRect
    }

    /// `orientation` matters for anything beyond a `UIImage` whose
    /// `.cgImage` already reflects the *displayed* orientation (a photo
    /// from `UIImagePickerController`/`PhotosPicker`, which is what
    /// `recognizeLines`'s callers use, and why it can leave this at the
    /// default `.up`). A live camera frame converted straight from a
    /// `CMSampleBuffer` is raw sensor data — for the back camera held in
    /// portrait, that's rotated 90° from what's on screen — so
    /// `ReceiptOCRScannerView` passes `.right` explicitly. Getting this
    /// wrong doesn't necessarily break text recognition itself (Vision
    /// tolerates some rotation), but it does put `boundingBox` in visibly
    /// the wrong place once something tries to draw it.
    func recognizeTextLines(in image: UIImage, orientation: CGImagePropertyOrientation = .up) async -> [RecognizedTextLine] {
        guard let cgImage = image.cgImage else {
            errorMessage = "Couldn't read that photo."
            return []
        }

        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { [weak self] request, error in
                if let error {
                    self?.errorMessage = error.localizedDescription
                    continuation.resume(returning: [])
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { observation -> RecognizedTextLine? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return RecognizedTextLine(text: text, boundingBox: observation.boundingBox)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                self.errorMessage = error.localizedDescription
                continuation.resume(returning: [])
            }
        }
    }

    /// Symmetric with `recognizeLines` — a Vision-based, single-image
    /// barcode reader, for a future "scan a barcode from a photo" mode.
    /// Not what powers `BarcodeScannerView`'s live, continuous scanning:
    /// that uses `AVCaptureMetadataOutput` instead, the OS's own
    /// hardware-accelerated barcode pipeline, since running a full Vision
    /// request on every live camera frame would be real, avoidable
    /// battery cost for no accuracy gain over the native API.
    func recognizeBarcodes(in image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else {
            errorMessage = "Couldn't read that photo."
            return []
        }

        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        return await withCheckedContinuation { continuation in
            let request = VNDetectBarcodesRequest { [weak self] request, error in
                if let error {
                    self?.errorMessage = error.localizedDescription
                    continuation.resume(returning: [])
                    return
                }
                let observations = (request.results as? [VNBarcodeObservation]) ?? []
                let codes = observations.compactMap(\.payloadStringValue)
                continuation.resume(returning: codes)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                self.errorMessage = error.localizedDescription
                continuation.resume(returning: [])
            }
        }
    }
}
