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
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
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
