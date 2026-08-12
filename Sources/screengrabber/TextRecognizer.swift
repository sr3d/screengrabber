import AppKit
import Vision

/// On-device OCR via the Vision framework. No entitlement, no usage-description
/// string, and no network — text recognition runs entirely locally.
enum TextRecognizer {

    /// Recognizes the text in `image` and hands back one string with the lines
    /// already sorted into reading order. `completion` is called on the main
    /// queue; an empty string means nothing was recognized (or the request
    /// failed, which is logged).
    static func recognize(in image: CGImage, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            // Revision 3 (macOS 13+) is the current engine: better accuracy plus
            // handwriting, rotated text, and automatic language detection.
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Screenshots can be in any language, and we have no domain hint.
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("ScreenGrabber: text recognition failed: \(error)")
                DispatchQueue.main.async { completion("") }
                return
            }

            let text = readingOrderText(from: request.results ?? [])
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// Vision returns observations in no guaranteed order, so group them into
    /// rows top-to-bottom and sort each row left-to-right before joining.
    private static func readingOrderText(from observations: [VNRecognizedTextObservation]) -> String {
        // Bounding boxes are normalized with a bottom-left origin, so a larger
        // midY means higher up the page.
        let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var rows: [[VNRecognizedTextObservation]] = []
        for o in sorted {
            // Same row if its center falls within half a line-height of the row's
            // first (tallest-placed) observation — tolerant of baseline wobble
            // between columns without merging genuinely separate lines.
            if let last = rows.last, let ref = last.first {
                let tolerance = max(ref.boundingBox.height, o.boundingBox.height) / 2
                if abs(ref.boundingBox.midY - o.boundingBox.midY) <= tolerance {
                    rows[rows.count - 1].append(o)
                    continue
                }
            }
            rows.append([o])
        }

        return rows.map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
        }
        .joined(separator: "\n")
    }
}
